drop table migrations cascade;
create table migrations(
    id int unique not null,
    description text,
    --execution_status text not null CHECK (execution_status in ('success', 'error')),
    success bool not null,
    author text,
    diagnostics jsonb default '[]',
    extra jsonb default '{}',
    created_at timestamptz not null
    --updated_at timestamptz,
    --sql_commands text not null,
    --version text not null
);

insert into migrations(
    id,
    description,
    success,
    created_at
)
values (
    0,
    'initial empty migration',
    't',
    now()
);

drop table xyz;
drop type mood cascade;
drop type mood3 cascade;
drop type mood4 cascade;
drop type mood5 cascade;
select * from xyz
select * from migrations;

create table xyz()
select * from migrate('001', $$alter table xyz add column col290 text;$$,'desc 001', 'author1');
select * from migrate('002', $$alter table xyz add column col290 text;$$,'desc 002 - will fail', 'author1');
select * from migrate('002', $$alter table xyz add column col291 text;$$,'desc 002 - edited', 'author2');
select * from migrate('003', $$CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy'); alter table xyz add column col292 mood;$$,'desc 003 - will fail', 'author1');
select * from migrate('004', $$alter table xyz drop column col291;$$,'desc 004', 'author1');
select * from migrate('005', $$alter  table xyz drop column col292;$$,'desc 005', 'author1');
select * from migrate('006', $$alter  table xyz drop column col290;$$,'desc 006', 'author1');
select * from migrate(7, $$  CREATE TYPE mood3 AS ENUM ('sad', 'ok', 'happy', 'depressed');$$,'desc 007', 'author2');
select * from migrate('08', $$  CREATE TYPE mood4 AS ENUM ('sad', 'ok', 'happy');$$,'desc 008', 'author1');
select * from migrate(9, $$  CREATE TYPE mood5 AS ENUM ('sad', 'ok', 'happy');$$,'desc 009', 'author1');




create view diagnostics as
select t.*
from (
           select
        id as migration_id, row_number() over (partition by id) as rn_migration,
                            r.* from migrations
    join lateral jsonb_to_recordset(diagnostics) as r(
        ts timestamptz,
        sql_commands text,
        description text,
        success bool,
        author text,
        message_text text,
        returned_sqlstate text
        --pg_exception_context text
    ) on true
    order by id desc, rn_migration desc
) t;

select * from diagnostics
--where success = 't' and sql_commands ~* '^.*(drop|xyz).*$'
where sql_commands ~* '^alter.*xyz.*281'






DROP FUNCTION diagnostics(TEXT);
CREATE OR REPLACE FUNCTION diagnostics(search_pattern TEXT = '')
RETURNS SETOF diagnostics
AS $$
DECLARE
    diagnostics_query TEXT;
BEGIN

    search_pattern = btrim(search_pattern);

    diagnostics_query = 'select * from diagnostics where success = true';

    if search_pattern <> '' then
        diagnostics_query = diagnostics_query || format(' and sql_commands ~* ''%s'' ', search_pattern);
    end if;

    --raise notice 'diagnostics_query: %', diagnostics_query;

    RETURN QUERY EXECUTE diagnostics_query;

END;
$$ language plpgsql;

select * from diagnostics()
select * from diagnostics('mood3.*enum')



DROP FUNCTION migrate(TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION migrate(migration_id TEXT, sql_commands TEXT, migration_description TEXT default null, migration_author TEXT default null, OUT migrate_code TEXT, OUT execution_diagnostics TEXT)
RETURNS record
AS $$
DECLARE
    --_version TEXT = '0.1';
    previous_success_migration record;
    expected_migration_id int;
    diagnostics_obj JSONB;
    _message_text TEXT;
    _returned_sqlstate TEXT;
    -- _pg_exception_context TEXT;
    -- _pg_exception_detail TEXT;
    -- _pg_exception_hint TEXT;
BEGIN

    select *
    from migrations
    where success = 't'
    order by id desc
    limit 1
    INTO STRICT previous_success_migration;

    -- cases where we do an early return

    expected_migration_id = previous_success_migration.id + 1;

    if migration_id !~ '^\d+$' then
        migrate_code = 'invalid_migration_id';
    elseif migration_id::int < expected_migration_id then
        migrate_code = 'migration_already_done';
    elseif migration_id::int > expected_migration_id then
        migrate_code = 'unexpected_migration_id';
    end if;

    if migrate_code is not null then
        raise notice 'migration %: %', migration_id, migrate_code;

        return;
    end if;

    -- proceed: try to execute the given sql commands

    sql_commands = btrim(sql_commands);
    execute sql_commands;

    -- if we arrive here, the sql commands were executed with success

    diagnostics_obj = jsonb_build_object(
        'ts', now(),
        'sql_commands', sql_commands,
        'description', migration_description,
        'success', true,
        'author', migration_author
    );

    insert into migrations(
        id,
        description,
        success,
        author,
        diagnostics,
        created_at
    )
    values (
        migration_id::int,
        migration_description,
        't',
        migration_author,
        '[]'::jsonb || diagnostics_obj,
        now()
    )
    on conflict (id)
    DO UPDATE SET
        description = migration_description,
        success = 't',
        author = migration_author,
        diagnostics = migrations.diagnostics || diagnostics_obj,
        created_at = now();

    migrate_code = 'success';
    raise notice 'migration %: %', migration_id, migrate_code;

    return;

EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS
        _message_text = message_text,
        _returned_sqlstate = returned_sqlstate;
        -- _pg_exception_context = pg_exception_context;
        --_pg_exception_detail = pg_exception_detail,
        --_pg_exception_hint = pg_exception_hint;

    diagnostics_obj = jsonb_build_object(
        'ts', now(),
        'sql_commands', sql_commands,
        'description', migration_description,
        'success', false,
        'author', migration_author,
        'message_text', _message_text,
        'returned_sqlstate', _returned_sqlstate
        -- 'pg_exception_context', _pg_exception_context
        --'pg_exception_detail', _pg_exception_detail,
        --'pg_exception_hint', _pg_exception_hint
    );

    insert into migrations(
        id,
        description,
        success,
        author,
        diagnostics,
        created_at
        --version
    )
    values (
        migration_id::int,
        migration_description,
        'f',
        migration_author,
        '[]'::jsonb || diagnostics_obj,
        now()
        --_version
    )
    on conflict (id)
    DO UPDATE SET
        description = migration_description,
        success = 'f',
        author = migration_author,
        diagnostics = migrations.diagnostics || diagnostics_obj,
        created_at = now();
        --version = _version;

    migrate_code = 'error';

    if _returned_sqlstate = '42601' then
        migrate_code = 'syntax_error';  -- special case
    end if;

    execution_diagnostics = diagnostics_obj;

    raise notice 'migration %: %', migration_id, migrate_code;

    return;

END;
$$ language plpgsql;

-- wrapper function for the case where migration_id is given as an integer (instead of a text)

DROP FUNCTION migrate(INT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION migrate(migration_id INT, sql_commands TEXT, migration_description TEXT default null, migration_author TEXT default null, OUT migrate_code TEXT, OUT execution_diagnostics TEXT)
RETURNS record
AS $$
DECLARE
    out record;
BEGIN

    select *
    from migrate(migration_id::text, sql_commands, migration_description, migration_author)
    INTO STRICT out;

    migrate_code = out.migrate_code;
    execution_diagnostics = out.execution_diagnostics;

END;
$$ language plpgsql;

