package OpenILS::WWW::EGCatLoader;
use strict; use warnings;
use Apache2::Const -compile => qw(OK DECLINED FORBIDDEN HTTP_INTERNAL_SERVER_ERROR REDIRECT HTTP_BAD_REQUEST);
use OpenSRF::Utils::Logger qw/$logger/;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Application::AppUtils;
use OpenSRF::Utils::JSON;
my $U = 'OpenILS::Application::AppUtils';

sub load_extended_user_info {
    my $self = shift;

    $self->ctx->{user} = $self->editor->retrieve_actor_user([
        $self->ctx->{user}->id,
        {
            flesh => 1,
            flesh_fields => {
                au => [qw/card home_ou addresses ident_type billing_address/]
                # ...
            }
        }
    ]) or return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;

    return;
}

# context additions: 
#   user : au object, fleshed
sub load_myopac_prefs {
    my $self = shift;
    return $self->load_extended_user_info || Apache2::Const::OK;
}

sub load_myopac_prefs_notify {
    my $self = shift;
    my $e = $self->editor;

    my $user_prefs = $self->fetch_optin_prefs;
    $user_prefs = $self->update_optin_prefs($user_prefs)
        if $self->cgi->request_method eq 'POST';

    $self->ctx->{opt_in_settings} = $user_prefs; 

    return Apache2::Const::OK;
}

sub fetch_optin_prefs {
    my $self = shift;
    my $e = $self->editor;

    # fetch all of the opt-in settings the user has access to
    # XXX: user's should in theory have options to opt-in to notices
    # for remote locations, but that opens the door for a large
    # set of generally un-used opt-ins.. needs discussion
    my $opt_ins =  $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.event_def.opt_in.settings.atomic',
        $e->authtoken, $e->requestor->home_ou);

    # fetch user setting values for each of the opt-in settings
    my $user_set = $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.patron.settings.retrieve',
        $e->authtoken, 
        $e->requestor->id, 
        [map {$_->name} @$opt_ins]
    );

    return [map { {cust => $_, value => $user_set->{$_->name} } } @$opt_ins];
}

sub update_optin_prefs {
    my $self = shift;
    my $user_prefs = shift;
    my $e = $self->editor;
    my @settings = $self->cgi->param('setting');
    my %newsets;

    # apply now-true settings
    for my $applied (@settings) {
        # see if setting is already applied to this user
        next if grep { $_->{cust}->name eq $applied and $_->{value} } @$user_prefs;
        $newsets{$applied} = OpenSRF::Utils::JSON->true;
    }

    # remove now-false settings
    for my $pref (grep { $_->{value} } @$user_prefs) {
        $newsets{$pref->{cust}->name} = undef 
            unless grep { $_ eq $pref->{cust}->name } @settings;
    }

    $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.patron.settings.update',
        $e->authtoken, $e->requestor->id, \%newsets);

    # update the local prefs to match reality
    for my $pref (@$user_prefs) {
        $pref->{value} = $newsets{$pref->{cust}->name} 
            if exists $newsets{$pref->{cust}->name};
    }

    return $user_prefs;
}

sub load_myopac_prefs_settings {
    my $self = shift;
    return $self->load_extended_user_info || Apache2::Const::OK;
}

sub fetch_user_holds {
    my $self = shift;
    my $hold_ids = shift;
    my $ids_only = shift;
    my $flesh = shift;
    my $available = shift;
    my $limit = shift;
    my $offset = shift;

    my $e = $self->editor;

    my $circ = OpenSRF::AppSession->create('open-ils.circ');

    if(!$hold_ids) {

        $hold_ids = $circ->request(
            'open-ils.circ.holds.id_list.retrieve.authoritative', 
            $e->authtoken, 
            $e->requestor->id
        )->gather(1);
    
        $hold_ids = [ grep { defined $_ } @$hold_ids[$offset..($offset + $limit - 1)] ] if $limit or $offset;
    }


    return $hold_ids if $ids_only or @$hold_ids == 0;

    my $args = {
        suppress_notices => 1,
        suppress_transits => 1,
        suppress_mvr => 1,
        suppress_patron_details => 1,
        include_bre => $flesh ? 1 : 0
    };

    # ----------------------------------------------------------------
    # Collect holds in batches of $batch_size for faster retrieval

    my $batch_size = 8;
    my $batch_idx = 0;
    my $mk_req_batch = sub {
        my @ses;
        my $top_idx = $batch_idx + $batch_size;
        while($batch_idx < $top_idx) {
            my $hold_id = $hold_ids->[$batch_idx++];
            last unless $hold_id;
            my $ses = OpenSRF::AppSession->create('open-ils.circ');
            my $req = $ses->request(
                'open-ils.circ.hold.details.retrieve', 
                $e->authtoken, $hold_id, $args);
            push(@ses, {ses => $ses, req => $req});
        }
        return @ses;
    };

    my $first = 1;
    my(@collected, @holds, @ses);

    while(1) {
        @ses = $mk_req_batch->() if $first;
        last if $first and not @ses;

        if(@collected) {
            # If desired by the caller, filter any holds that are not available.
            if ($available) {
                @collected = grep { $_->{hold}->{status} == 4 } @collected;
            }
            while(my $blob = pop(@collected)) {
                $blob->{marc_xml} = XML::LibXML->new->parse_string($blob->{hold}->{bre}->marc) if $flesh;
                push(@holds, $blob);
            }
        }

        for my $req_data (@ses) {
            push(@collected, {hold => $req_data->{req}->gather(1)});
            $req_data->{ses}->kill_me;
        }

        @ses = $mk_req_batch->();
        last unless @collected or @ses;
        $first = 0;
    }

    # put the holds back into the original server sort order
    my @sorted;
    for my $id (@$hold_ids) {
        push @sorted, grep { $_->{hold}->{hold}->id == $id } @holds;
    }

    return \@sorted;
}

sub handle_hold_update {
    my $self = shift;
    my $action = shift;
    my $e = $self->editor;
    my $url;

    my @hold_ids = $self->cgi->param('hold_id'); # for non-_all actions
    @hold_ids = @{$self->fetch_user_holds(undef, 1)} if $action =~ /_all/;

    my $circ = OpenSRF::AppSession->create('open-ils.circ');

    if($action =~ /cancel/) {

        for my $hold_id (@hold_ids) {
            my $resp = $circ->request(
                'open-ils.circ.hold.cancel', $e->authtoken, $hold_id, 6 )->gather(1); # 6 == patron-cancelled-via-opac
        }

    } elsif ($action =~ /activate|suspend/) {
        
        my $vlist = [];
        for my $hold_id (@hold_ids) {
            my $vals = {id => $hold_id};

            if($action =~ /activate/) {
                $vals->{frozen} = 'f';
                $vals->{thaw_date} = undef;

            } elsif($action =~ /suspend/) {
                $vals->{frozen} = 't';
                # $vals->{thaw_date} = TODO;
            }
            push(@$vlist, $vals);
        }

        $circ->request('open-ils.circ.hold.update.batch.atomic', $e->authtoken, undef, $vlist)->gather(1);
    } elsif ($action eq 'edit') {

        my @vals = map {
            my $val = {"id" => $_};
            $val->{"frozen"} = $self->cgi->param("frozen");
            $val->{"pickup_lib"} = $self->cgi->param("pickup_lib");

            for my $field (qw/expire_time thaw_date/) {
                # XXX TODO make this support other date formats, not just
                # MM/DD/YYYY.
                next unless $self->cgi->param($field) =~
                    m:^(\d{2})/(\d{2})/(\d{4})$:;
                $val->{$field} = "$3-$1-$2";
            }
            $val;
        } @hold_ids;

        $circ->request(
            'open-ils.circ.hold.update.batch.atomic',
            $e->authtoken, undef, \@vals
        )->gather(1);   # LFW XXX test for failure
        $url = 'https://' . $self->apache->hostname . $self->ctx->{opac_root} . '/myopac/holds';
    }

    $circ->kill_me;
    return defined($url) ? $self->generic_redirect($url) : undef;
}

sub load_myopac_holds {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    

    my $limit = $self->cgi->param('limit') || 0;
    my $offset = $self->cgi->param('offset') || 0;
    my $action = $self->cgi->param('action') || '';
    my $available = int($self->cgi->param('available') || 0);

    my $hold_handle_result;
    $hold_handle_result = $self->handle_hold_update($action) if $action;

    $ctx->{holds} = $self->fetch_user_holds(undef, 0, 1, $available, $limit, $offset);

    return defined($hold_handle_result) ? $hold_handle_result : Apache2::Const::OK;
}

sub load_place_hold {
    my $self = shift;
    my $ctx = $self->ctx;
    my $e = $self->editor;
    my $cgi = $self->cgi;
    $self->ctx->{page} = 'place_hold';

    $ctx->{hold_target} = $cgi->param('hold_target');
    $ctx->{hold_type} = $cgi->param('hold_type');
    $ctx->{default_pickup_lib} = $e->requestor->home_ou; # XXX staff

    if ($ctx->{hold_type} eq 'T') {
        $ctx->{record} = $e->retrieve_biblio_record_entry($ctx->{hold_target});
    } elsif ($ctx->{hold_type} eq 'I') {
        my $iss = $e->retrieve_serial_issuance([
            $ctx->{hold_target}, {
                "flesh" => 2,
                "flesh_fields" => {
                    "siss" => ["subscription"], "ssub" => ["record_entry"]
                }
            }
        ]);
        $ctx->{record} = $iss->subscription->record_entry;
    }
    # ...

    $ctx->{marc_xml} = XML::LibXML->new->parse_string($ctx->{record}->marc);

    if(my $pickup_lib = $cgi->param('pickup_lib')) {

        my $args = {
            patronid => $e->requestor->id,
            titleid => $ctx->{hold_target}, # XXX
            pickup_lib => $pickup_lib,
            depth => 0, # XXX
        };

        my $allowed = $U->simplereq(
            'open-ils.circ',
            'open-ils.circ.title_hold.is_possible',
            $e->authtoken, $args
        );

        if($allowed->{success} == 1) {
            my $hold = Fieldmapper::action::hold_request->new;

            $hold->pickup_lib($pickup_lib);
            $hold->requestor($e->requestor->id);
            $hold->usr($e->requestor->id); # XXX staff
            $hold->target($ctx->{hold_target});
            $hold->hold_type($ctx->{hold_type});
            # frozen, expired, etc..

            my $stat = $U->simplereq(
                'open-ils.circ',
                'open-ils.circ.holds.create',
                $e->authtoken, $hold
            );

            if($stat and $stat > 0) {
                # if successful, return the user to the requesting page
                $self->apache->log->info("Redirecting back to " . $cgi->param('redirect_to'));
                return $self->generic_redirect;

            } else {
                $ctx->{hold_failed} = 1;
            }
        } else { # hold *check* failed
            $ctx->{hold_failed} = 1; # XXX process the events, etc
            $ctx->{hold_failed_event} = $allowed->{last_event};
        }

        # hold permit failed
        $logger->info('hold permit result ' . OpenSRF::Utils::JSON->perl2JSON($allowed));
    }

    return Apache2::Const::OK;
}


sub fetch_user_circs {
    my $self = shift;
    my $flesh = shift; # flesh bib data, etc.
    my $circ_ids = shift;
    my $limit = shift;
    my $offset = shift;

    my $e = $self->editor;

    my @circ_ids;

    if($circ_ids) {
        @circ_ids = @$circ_ids;

    } else {

        my $circ_data = $U->simplereq(
            'open-ils.actor', 
            'open-ils.actor.user.checked_out',
            $e->authtoken, 
            $e->requestor->id
        );

        @circ_ids =  ( @{$circ_data->{overdue}}, @{$circ_data->{out}} );

        if($limit or $offset) {
            @circ_ids = grep { defined $_ } @circ_ids[0..($offset + $limit - 1)];
        }
    }

    return [] unless @circ_ids;

    my $cstore = OpenSRF::AppSession->create('open-ils.cstore');

    my $qflesh = {
        flesh => 3,
        flesh_fields => {
            circ => ['target_copy'],
            acp => ['call_number'],
            acn => ['record']
        }
    };

    $e->xact_begin;
    my $circs = $e->search_action_circulation(
        [{id => \@circ_ids}, ($flesh) ? $qflesh : {}], {substream => 1});

    my @circs;
    for my $circ (@$circs) {
        push(@circs, {
            circ => $circ, 
            marc_xml => ($flesh and $circ->target_copy->call_number->id != -1) ? 
                XML::LibXML->new->parse_string($circ->target_copy->call_number->record->marc) : 
                undef  # pre-cat copy, use the dummy title/author instead
        });
    }
    $e->xact_rollback;

    # make sure the final list is in the correct order
    my @sorted_circs;
    for my $id (@circ_ids) {
        push(
            @sorted_circs,
            (grep { $_->{circ}->id == $id } @circs)
        );
    }

    return \@sorted_circs;
}


sub handle_circ_renew {
    my $self = shift;
    my $action = shift;
    my $ctx = $self->ctx;

    my @renew_ids = $self->cgi->param('circ');

    my $circs = $self->fetch_user_circs(0, ($action eq 'renew') ? [@renew_ids] : undef);

    # TODO: fire off renewal calls in batches to speed things up
    my @responses;
    for my $circ (@$circs) {

        my $evt = $U->simplereq(
            'open-ils.circ', 
            'open-ils.circ.renew',
            $self->editor->authtoken,
            {
                patron_id => $self->editor->requestor->id,
                copy_id => $circ->{circ}->target_copy,
                opac_renewal => 1
            }
        );

        # TODO return these, then insert them into the circ data 
        # blob that is shoved into the template for each circ
        # so the template won't have to match them
        push(@responses, {copy => $circ->{circ}->target_copy, evt => $evt});
    }

    return @responses;
}


sub load_myopac_circs {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;

    $ctx->{circs} = [];
    my $limit = $self->cgi->param('limit') || 0; # 0 == unlimited
    my $offset = $self->cgi->param('offset') || 0;
    my $action = $self->cgi->param('action') || '';

    # perform the renewal first if necessary
    my @results = $self->handle_circ_renew($action) if $action =~ /renew/;

    $ctx->{circs} = $self->fetch_user_circs(1, undef, $limit, $offset);

    my $success_renewals = 0;
    my $failed_renewals = 0;
    for my $data (@{$ctx->{circs}}) {
        my ($resp) = grep { $_->{copy} == $data->{circ}->target_copy->id } @results;

        if($resp) {
            my $evt = ref($resp->{evt}) eq 'ARRAY' ? $resp->{evt}->[0] : $resp->{evt};
            $data->{renewal_response} = $evt;
            $success_renewals++ if $evt->{textcode} eq 'SUCCESS';
            $failed_renewals++ if $evt->{textcode} ne 'SUCCESS';
        }
    }

    $ctx->{success_renewals} = $success_renewals;
    $ctx->{failed_renewals} = $failed_renewals;

    return Apache2::Const::OK;
}

sub load_myopac_circ_history {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $limit = $self->cgi->param('limit') || 15;
    my $offset = $self->cgi->param('offset') || 0;

    $ctx->{circ_history_limit} = $limit;
    $ctx->{circ_history_offset} = $offset;

    my $circs = $e->json_query({
        from => ['action.usr_visible_circs', $e->requestor->id],
        #limit => $limit || 25,
        #offset => $offset || 0,
    });

    # XXX: order-by in the json_query above appears to do nothing, so in-query 
    # paging is not reallly an option.  do the sorting/paging here

    # sort newest to oldest
    $circs = [ sort { $b->{xact_start} cmp $a->{xact_start} } @$circs ];
    my @ids = map { $_->{id} } @$circs;

    # find the selected page and trim cruft
    @ids = @ids[$offset..($offset + $limit - 1)] if $limit;
    @ids = grep { defined $_ } @ids;

    $ctx->{circs} = $self->fetch_user_circs(1, \@ids);
    #$ctx->{circs} = $self->fetch_user_circs(1, [map { $_->{id} } @$circs], $limit, $offset);

    return Apache2::Const::OK;
}

# TODO: action.usr_visible_holds does not return cancelled holds.  Should it?
sub load_myopac_hold_history {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $limit = $self->cgi->param('limit') || 15;
    my $offset = $self->cgi->param('offset') || 0;
    $ctx->{hold_history_limit} = $limit;
    $ctx->{hold_history_offset} = $offset;


    my $holds = $e->json_query({
        from => ['action.usr_visible_holds', $e->requestor->id],
        limit => $limit || 25,
        offset => $offset || 0
    });

    $ctx->{holds} = $self->fetch_user_holds([map { $_->{id} } @$holds], 0, 1, 0, $limit, $offset);

    return Apache2::Const::OK;
}

sub load_myopac_payment_form {
    my $self = shift;
    my $r = $self->load_fines(undef, undef, [$self->cgi->param('xact')]);
    return $r if $r;
    return $self->load_extended_user_info || Apache2::Const::OK;
}

# TODO: add other filter options as params/configs/etc.
sub load_myopac_payments {
    my $self = shift;
    my $limit = $self->cgi->param('limit') || 20;
    my $offset = $self->cgi->param('offset') || 0;
    my $e = $self->editor;

    $self->ctx->{payment_history_limit} = $limit;
    $self->ctx->{payment_history_offset} = $offset;

    my $args = {};
    $args->{limit} = $limit if $limit;
    $args->{offset} = $offset if $offset;

    $self->ctx->{payments} = $U->simplereq(
        'open-ils.actor',
        'open-ils.actor.user.payments.retrieve.atomic',
        $e->authtoken, $e->requestor->id, $args);

    return Apache2::Const::OK;
}

sub load_fines {
    my ($self, $limit, $offset, $id_list) = @_;

    # XXX TODO: check for failure after various network calls

    $self->ctx->{"fines"} = {
        "circulation" => [],
        "grocery" => [],
        "total_paid" => 0,
        "total_owed" => 0,
        "balance_owed" => 0
    };

    my $cstore = OpenSRF::AppSession->create('open-ils.cstore');

    # TODO: This should really be a ML call, but the existing calls 
    # return an excessive amount of data and don't offer streaming

    my %paging = ($limit or $offset) ? (limit => $limit, offset => $offset) : ();

    my $req = $cstore->request(
        'open-ils.cstore.direct.money.open_billable_transaction_summary.search',
        {
            usr => $self->editor->requestor->id,
            balance_owed => {'!=' => 0},
            (ref $id_list eq 'ARRAY' ? ("id" => $id_list) : ()),
        },
        {
            flesh => 4,
            flesh_fields => {
                mobts => [qw/grocery circulation reservation/],
                bresv => ['target_resource_type'],
                brt => ['record'],
                mg => ['billings'],
                mb => ['btype'],
                circ => ['target_copy'],
                acp => ['call_number'],
                acn => ['record']
            },
            order_by => { mobts => 'xact_start' },
            %paging
        }
    );

    while(my $resp = $req->recv) {
        my $mobts = $resp->content;
        my $circ = $mobts->circulation;

        my $last_billing;
        if($mobts->grocery) {
            my @billings = sort { $a->billing_ts cmp $b->billing_ts } @{$mobts->grocery->billings};
            $last_billing = pop(@billings);
        }

        # XXX TODO switch to some money-safe non-fp library for math
        $self->ctx->{"fines"}->{$_} += $mobts->$_ for (
            qw/total_paid total_owed balance_owed/
        );

        my $marc_xml = undef;
        if ($mobts->xact_type eq 'reservation' and
            $mobts->reservation->target_resource_type->record) {
            $marc_xml = XML::LibXML->new->parse_string(
                $mobts->reservation->target_resource_type->record->marc
            );
        } elsif ($mobts->xact_type eq 'circulation' and
            $circ->target_copy->call_number->id != -1) {
            $marc_xml = XML::LibXML->new->parse_string(
                $circ->target_copy->call_number->record->marc
            );
        }

        push(
            @{$self->ctx->{"fines"}->{$mobts->grocery ? "grocery" : "circulation"}},
            {
                xact => $mobts,
                last_grocery_billing => $last_billing,
                marc_xml => $marc_xml
            } 
        );
    }

     return;
}

sub load_myopac_main {
    my $self = shift;
    my $limit = $self->cgi->param('limit') || 0;
    my $offset = $self->cgi->param('offset') || 0;

    return $self->load_fines($limit, $offset) || Apache2::Const::OK;
}

sub load_myopac_update_email {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $email = $self->cgi->param('email') || '';

    return Apache2::Const::OK 
        unless $self->cgi->request_method eq 'POST';

    unless($email =~ /.+\@.+\..+/) { # TODO better regex?
        $ctx->{invalid_email} = $email;
        return Apache2::Const::OK;
    }

    my $stat = $U->simplereq(
        'open-ils.actor', 
        'open-ils.actor.user.email.update', 
        $e->authtoken, $email);

    my $url = $self->apache->unparsed_uri;
    $url =~ s/update_email/prefs/;

    return $self->generic_redirect($url);
}

sub load_myopac_update_username {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;
    my $username = $self->cgi->param('username') || '';

    return Apache2::Const::OK 
        unless $self->cgi->request_method eq 'POST';

    unless($username and $username !~ /\s/) { # any other username restrictions?
        $ctx->{invalid_username} = $username;
        return Apache2::Const::OK;
    }

    if($username ne $e->requestor->usrname) {

        my $evt = $U->simplereq(
            'open-ils.actor', 
            'open-ils.actor.user.username.update', 
            $e->authtoken, $username);

        if($U->event_equals($evt, 'USERNAME_EXISTS')) {
            $ctx->{username_exists} = $username;
            return Apache2::Const::OK;
        }
    }

    my $url = $self->apache->unparsed_uri;
    $url =~ s/update_username/prefs/;

    return $self->generic_redirect($url);
}

sub load_myopac_update_password {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;

    return Apache2::Const::OK 
        unless $self->cgi->request_method eq 'POST';

    my $current_pw = $self->cgi->param('current_pw') || '';
    my $new_pw = $self->cgi->param('new_pw') || '';
    my $new_pw2 = $self->cgi->param('new_pw2') || '';

    unless($new_pw eq $new_pw2) {
        $ctx->{password_nomatch} = 1;
        return Apache2::Const::OK;
    }

    my $pw_regex = $ctx->{get_org_setting}->($e->requestor->home_ou, 'global.password_regex');

    if($pw_regex and $new_pw !~ /$pw_regex/) {
        $ctx->{password_invalid} = 1;
        return Apache2::Const::OK;
    }

    my $evt = $U->simplereq(
        'open-ils.actor', 
        'open-ils.actor.user.password.update', 
        $e->authtoken, $new_pw, $current_pw);


    if($U->event_equals($evt, 'INCORRECT_PASSWORD')) {
        $ctx->{password_incorrect} = 1;
        return Apache2::Const::OK;
    }

    my $url = $self->apache->unparsed_uri;
    $url =~ s/update_password/prefs/;

    return $self->generic_redirect($url);
}

sub load_myopac_bookbags {
    my $self = shift;
    my $e = $self->editor;
    my $ctx = $self->ctx;

    $e->xact_begin; # replication...

    my $rv = $self->load_mylist;
    unless($rv eq Apache2::Const::OK) {
        $e->rollback;
        return $rv;
    }

    my $args = {
        order_by => {cbreb => 'name'},
        limit => $self->cgi->param('limit') || 10,
        offset => $self->cgi->param('offset') || 0
    };

    $ctx->{bookbags} = $e->search_container_biblio_record_entry_bucket([
        {owner => $self->editor->requestor->id, btype => 'bookbag'},
        # XXX what to do about the possibility of really large bookbags here?
        {"flesh" => 1, "flesh_fields" => {"cbreb" => ["items"]}, %$args}
    ]);

    if(!$ctx->{bookbags}) {
        $e->rollback;
        return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;
    }
    
    # get unique record IDs
    my %rec_ids = ();
    foreach my $bbag (@{$ctx->{bookbags}}) {
        foreach my $rec_id (
            map { $_->target_biblio_record_entry } @{$bbag->items}
        ) {
            $rec_ids{$rec_id} = 1;
        }
    }

    $ctx->{bookbags_marc_xml} = $self->fetch_marc_xml_by_id([keys %rec_ids]);

    $e->rollback;
    return Apache2::Const::OK;
}


# actions are create, delete, show, hide, rename, add_rec, delete_item
# CGI is action, list=list_id, add_rec/record=bre_id, del_item=bucket_item_id, name=new_bucket_name
sub load_myopac_bookbag_update {
    my ($self, $action, $list_id) = @_;
    my $e = $self->editor;
    my $cgi = $self->cgi;

    $action ||= $cgi->param('action');
    $list_id ||= $cgi->param('list');

    my @add_rec = $cgi->param('add_rec') || $cgi->param('record');
    my @del_item = $cgi->param('del_item');
    my $shared = $cgi->param('shared');
    my $name = $cgi->param('name');
    my $success = 0;
    my $list;

    if($action eq 'create') {
        $list = Fieldmapper::container::biblio_record_entry_bucket->new;
        $list->name($name);
        $list->owner($e->requestor->id);
        $list->btype('bookbag');
        $list->pub($shared ? 't' : 'f');
        $success = $U->simplereq('open-ils.actor', 
            'open-ils.actor.container.create', $e->authtoken, 'biblio', $list)

    } else {

        $list = $e->retrieve_container_biblio_record_entry_bucket($list_id);

        return Apache2::Const::HTTP_BAD_REQUEST unless 
            $list and $list->owner == $e->requestor->id;
    }

    if($action eq 'delete') {
        $success = $U->simplereq('open-ils.actor', 
            'open-ils.actor.container.full_delete', $e->authtoken, 'biblio', $list_id);

    } elsif($action eq 'show') {
        unless($U->is_true($list->pub)) {
            $list->pub('t');
            $success = $U->simplereq('open-ils.actor', 
                'open-ils.actor.container.update', $e->authtoken, 'biblio', $list);
        }

    } elsif($action eq 'hide') {
        if($U->is_true($list->pub)) {
            $list->pub('f');
            $success = $U->simplereq('open-ils.actor', 
                'open-ils.actor.container.update', $e->authtoken, 'biblio', $list);
        }

    } elsif($action eq 'rename') {
        if($name) {
            $list->name($name);
            $success = $U->simplereq('open-ils.actor', 
                'open-ils.actor.container.update', $e->authtoken, 'biblio', $list);
        }

    } elsif($action eq 'add_rec') {
        foreach my $add_rec (@add_rec) {
            my $item = Fieldmapper::container::biblio_record_entry_bucket_item->new;
            $item->bucket($list_id);
            $item->target_biblio_record_entry($add_rec);
            $success = $U->simplereq('open-ils.actor', 
                'open-ils.actor.container.item.create', $e->authtoken, 'biblio', $item);
            last unless $success;
        }

    } elsif($action eq 'del_item') {
        foreach (@del_item) {
            $success = $U->simplereq(
                'open-ils.actor',
                'open-ils.actor.container.item.delete', $e->authtoken, 'biblio', $_
            );
            last unless $success;
        }
    }

    return $self->generic_redirect if $success;

    $self->ctx->{bucket_action} = $action;
    $self->ctx->{bucket_action_failed} = 1;
    return Apache2::Const::OK;
}

1
