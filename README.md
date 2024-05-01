# pg-simple-migrations
simple migrations for postgresql, without leaving the database

- works with postgres 9.4 or above

when an error occurs, we can inspect

```sql
select jsonb_array_elements(t.diagnostics) from (
    select diagnostics
    from migrations
    order by id desc
    limit 1
) t;
```

TODO: create a inspection helper:

```sql
select
    row_number() over () as rn,
    id as migration_id,
    row_number() over (partition by id) as rn_migration,
    r.*
from migrations
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
order by id desc, rn_migration desc;

select * from show_diagnostics()
```

```sql
select * from show_last()
```

after each migration is run, get a full inspection of the schema:

- `pg_dump`
- `psql --dbname=... --command="\d xyz"`
- pgddl - DDL eXtractor functions for PostgreSQL (ddlx) https://github.com/lacanoid/pgddl
- atlas - tool for managing and migrating database schemas using modern DevOps principles https://github.com/ariga/atlas


find previous migrations:

```
select * 
from show_diagnostics()
where success = 't' and sql_command ~* '^.*(my_table).*$'
```

helper: for simple cases like the previous, we can use this helper (it's equivalent)
```
select * from search_migration('my_table')
```

it will wrap the given string with '^.*(' and ').*$'

for more complex cases, you can provide the regexp yourself. 

For instance, to search for migrations that look like 'alter table xyz drop column something' (that is, that have 'xyz' somewhere and also 'drop' somewhere after 'xyz'):

```
select * from search_migration('xyz.*drop')
```


```
export PGDATABASE=something_wrong (to make sure it has effect)
export PGUSER=...
export PGPASSWORD=...
export PGHOST=...
export PGPORT=...

pg_dump  \
    --schema-only  \
    --schema=public \
    --table=public.* \
    --schema=other_schema \
    --table=other_schema.* \
    --exclude-table-data=*.* \
    --file=output.sql
```




other options for pg_dump that make little or no difference (for some of them, the used options are the default values):

```
--format=plain
--encoding=UTF8
--no-tablespaces
--no-owner
--no-privileges
```




NOTE: there 2 ways to create the dump in "schema-only" mode, for inspection: with or without the "--table" option

pg_dump  \
    --schema=schema_name \
    --schema-only  \
    --file=output1.sql


pg_dump  \
    --schema=schema_name \
    --schema-only  \
    --table=schema_name.* \
    --file=output8c.sql

The difference is: 
- with the "--table" option, it will output only tables (not functions, views, enums, etc)
- without the "--table" option, it will output the definition of other objects beside tables

If the schema is crowded with lots of functions (from some extension, like postgis, which will install the functions in the public schema), we might want to use "--table=schema_name.*" to output only the tables; but then we loose some of the other objects, like enums and views; it might make sense to do that and create an external script which would extract the enums from the other dump; for views and functions there is not much interest in being part of the dump; we can always see the latest definitions of those in their files (they are "repeatble" migrations);

It might also make sense to have separate dumps for individual tables; the name of the tables would be obtained dynamically, and pg_dump would be called for each table (?if the table uses the enum, would be enum be present?)

TO extract the enums using the full dump (without the "--table" option): call pg_dump without the "--file" option (so that it will output to stdout); use a regular expression that will extracct text between this pattern: 

```
CREATE TYPE public.chart_type2 AS ENUM (
    'lines',
    'bars',
    'radar',
    'gauge'
);
```


NOTE: data to test different options in pg_dump:

```
create schema migrations
create table migrations.abc(name text);
alter table migrations.abc add column user_id int references public.t_users(id);

create schema migrations2
create table migrations2.abc(name text);
alter table migrations2.abc add column user_id int references public.t_users(id);
create table migrations2.abc2(name text, user_id int references public.t_users(id));
alter table migrations2.abc2 add column something_else text not null;
insert into migrations2.abc2(name, something_else) values('xx2', 'yy2');
create type migrations2.mood as enum('x','y')
ALTER TYPE migrations2.mood ADD VALUE 'orange';
CREATE OR REPLACE FUNCTION migrations2.test()
RETURNS void
AS $$
BEGIN

    raise notice 'hello world';

END;
$$ language plpgsql;
```



NOTE: in both cases, we could have replaced "--schema-only" with "--exclude-table-data=schema_name.*"; the output would be the same;




IDEIAS:
create a schema just for functions
```
select * from fn.my_function()
```
this would be useful for
-distinguish between our user functions and other functions (built-in)
-for calling pg_dump with only the schema


MORE REFRENECES:
-https://github.com/sqlalchemy/alembic
-https://github.com/olirice/pg_migrate
-https://github.com/sqlalchemy/alembic
