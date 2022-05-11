drop table migrations;
create table migrations(
    id int unique not null,
    description text,
    status text not null CHECK (status in ('success', 'error')),
    author text,
    diagnostics jsonb,
    extra jsonb,
    created_at timestamptz not null,
    updated_at timestamptz,
    sql_commands text not null,
    version text not null
);

insert into migrations(
    id,
    description,
    status,
    author,
    created_at,
    sql_commands,
    version
)
values (
    0,
    'initial empty migration',
    'success',
    null,
    now(),
    '',
    '0.1'
);


select * from migrations;
select * from migrate('001', $$alter table xyz add column col50 text;$$,'desc 001');
select * from migrate('002', $$alter table xyz add column col50 text;$$,'desc 002 - will fail');
select * from migrate('002', $$alter table xyz add column col51 text;$$,'desc 002 - edited');
select * from migrate('003', $$CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy'); alter table xyz add column col52 mood;$$,'desc 003 - will fail');
select * from migrate('004', $$alter table xyz drop column col51;$$,'desc 004');


DROP FUNCTION migrate(TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION migrate(migration_id TEXT, _sql_commands TEXT, migration_description TEXT default null, migration_author TEXT default null, OUT execution_code TEXT, OUT execution_description TEXT, OUT execution_diagnostics TEXT)
RETURNS record
AS $$
DECLARE
    _message_text TEXT;
    _pg_exception_context TEXT;
    _returned_sqlstate TEXT;
    _pg_exception_detail TEXT;
    _pg_exception_hint TEXT;
    diagnostics_obj JSON;
    _version TEXT = '0.1';
    previous_migration record;
BEGIN

    select *
    from migrations
    order by id desc
    limit 1
    INTO STRICT previous_migration;

    -- early return, case 1: if the previous recorded migration had errors, those errors
    -- must be corrected (that migration must be successful)

    if previous_migration.status = 'error' and migration_id::int <> previous_migration.id then
        execution_code = 'error';
        execution_description = format('migration %s can''t proceed because the previous recorded migration (%s) has errors', migration_id::int, previous_migration.id);

        raise notice 'migration %: %', migration_id, execution_code;
        raise notice '%', execution_description;

        return;
    end if;

    -- early return, case 2: migration ids must be consecutive

    if previous_migration.status = 'success' and migration_id::int <> previous_migration.id + 1 then
        execution_code = 'error';
        execution_description = format('migration ids must be consecutive (the previous successful recorded migration is %s)', previous_migration.id);

        raise notice 'migration %: %', migration_id, execution_code;
        raise notice '%', execution_description;

        return;
    end if;

    -- proceed: try to execute the given sql commands

    execute _sql_commands;

    -- if we arrived here, the sql commands were executed with success

    insert into migrations(
        id,
        description,
        status,
        author,
        created_at,
        sql_commands,
        version
    )
    values (
        migration_id::int,
        migration_description,
        'success',
        migration_author,
        now(),
        _sql_commands,
        _version
    )
    on conflict (id)
    DO UPDATE SET
        description = migration_description,
        status = 'success',
        author = migration_author,
        diagnostics = null,
        updated_at = now(),
        sql_commands = _sql_commands,
        version = _version;

    execution_code = 'success';
    --execution_description = '';

    raise notice 'migration %: %', migration_id, execution_code;

    return;

EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS
        _message_text = MESSAGE_TEXT,
        _pg_exception_context = PG_EXCEPTION_CONTEXT,
        _returned_sqlstate = RETURNED_SQLSTATE,
        _pg_exception_detail = PG_EXCEPTION_DETAIL,
        _pg_exception_hint = PG_EXCEPTION_HINT;

    diagnostics_obj = json_build_object(
        'MESSAGE_TEXT', _message_text,
        'PG_EXCEPTION_CONTEXT', _pg_exception_context,
        'RETURNED_SQLSTATE', _returned_sqlstate,
        'PG_EXCEPTION_DETAIL', _pg_exception_detail,
        'PG_EXCEPTION_HINT', _pg_exception_hint
    );

    insert into migrations(
        id,
        description,
        status,
        author,
        diagnostics,
        created_at,
        sql_commands,
        version
    )
    values (
        migration_id::int,
        migration_description,
        'error',
        migration_author,
        diagnostics_obj,
        now(),
        _sql_commands,
        _version
    )
    on conflict (id)
    DO UPDATE SET
        description = migration_description,
        status = 'error',
        author = migration_author,
        diagnostics = diagnostics_obj,
        updated_at = now(),
        sql_commands = _sql_commands,
        version = _version;

    execution_code = 'error';
    execution_description = format('the sql commands in migration %s have errors (see diagnostics for more details)', migration_id);
    execution_diagnostics = diagnostics_obj;

    raise notice 'migration %: %', migration_id, execution_code;
    raise notice '%', execution_description;

    return;

END;
$$ language plpgsql;

