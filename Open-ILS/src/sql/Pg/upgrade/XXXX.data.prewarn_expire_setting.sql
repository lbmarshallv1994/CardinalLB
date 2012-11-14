BEGIN;

SELECT evergreen.upgrade_deps_block_check('XXXX', :eg_version);

INSERT INTO config.org_unit_setting_type
    (name, grp, label, description, datatype)
    VALUES (
        'circ.prewarn_expire_setting',
        'circ',
        oils_i18n_gettext(
            'circ.prewarn_expire_setting',
            'Pre-warning for patron expiration',
            'coust',
            'label'
        ),
        oils_i18n_gettext(
            'circ.prewarn_expire_setting',
            'Pre-warning for patron expiration. This setting defines the number of days before patron expiration to display a message suggesting it is time to renew the patron account. Value is in number of days, for example: 3 for 3 days.',
            'coust',
            'description'
        ),
        'integer'
    );

COMMIT;
