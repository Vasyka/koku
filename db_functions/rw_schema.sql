/*
Copyright 2020 Red Hat, Inc.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

DROP FUNCTION IF EXISTS public.read_schema(text, boolean);
CREATE OR REPLACE FUNCTION public.read_schema(
    source_schema text,
    _verbose boolean DEFAULT false
) RETURNS jsonb AS $$
DECLARE
    sequence_objects jsonb[];
    sequence_owner_info jsonb[];
    table_objects jsonb[];
    fk_objects jsonb[];
    view_objects jsonb[];
    function_objects jsonb[];
    trigger_objects jsonb[];
    rule_objects jsonb[];
    comment_objects jsonb[];
BEGIN
    /* Check if source schema exists */
    PERFORM oid
       FROM pg_namespace
      WHERE nspname = source_schema;
    IF NOT FOUND
    THEN
        RAISE WARNING 'Source schema % does not exist.', src_schema;
        RETURN '{}'::jsonb;
    END IF;

    /*
     * Gather data for copy
     */
    /* Sequence objects */
    IF _verbose THEN
        RAISE INFO 'Gathering sequence object data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
              jsonb_build_object(
                  'sequence_name', c.relname,
                  'sequence_type', s.seqtypid::regtype::text,
                  'sequence_start', s.seqstart,
                  'sequence_inc', s.seqincrement,
                  'sequence_max', s.seqmax,
                  'sequence_min', s.seqmin,
                  'sequence_cache', s.seqcache,
                  'sequence_cycle', CASE WHEN s.seqcycle THEN ' CYCLE' ELSE ' NO CYCLE' END::text,
                  'sequence_last_value', pg_sequence_last_value(s.seqrelid)
              )
           ), '{}'::jsonb[])
      INTO sequence_objects
      FROM pg_sequence s
      JOIN pg_class c
        ON c.oid = s.seqrelid
     WHERE c.relnamespace = source_schema::regnamespace;

    IF _verbose THEN
        RAISE INFO '    Got %s schema objects...', cardinality(sequence_objects);
    END IF;

    /* Sequence owner info */
    IF _verbose THEN
        RAISE INFO 'Gathering sequence owner data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'sequence_name', s.relname::text,
                   'owner_object', o.relname::text,
                   'owner_column', a.attname::text
               )
           ), '{}'::jsonb[])
      INTO sequence_owner_info
      FROM pg_depend d
      JOIN pg_attribute a
        ON a.attrelid = d.refobjid
       AND a.attnum = d.refobjsubid
      JOIN pg_class s
        ON s.oid = d.objid
       AND s.relkind = 'S'
      JOIN pg_class o
        ON o.oid = d.refobjid
     WHERE o.relnamespace = source_schema::regnamespace
       AND not o.relispartition;

    IF _verbose THEN
        RAISE INFO '    Got %s schema owner objects...', cardinality(sequence_owner_info);
    END IF;

    /* Table objects */
    IF _verbose THEN
        RAISE INFO 'Gathering table object data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'obj_id', t.oid,
                   'table_name', t.relname::text,
                   'table_kind', t.relkind::text,
                   'partition_type', CASE pt2.partstrat
                                          WHEN 'h' THEN 'HASH'
                                          WHEN 'l' THEN 'LIST'
                                          WHEN 'r' THEN 'RANGE'
                                          ELSE NULL
                                     END::text,
                   'partition_key', pk.attname::text,
                   'is_partition', t.relispartition,
                   'partitioned_table', p.relname,
                   'partition_expr', pg_get_expr(t.relpartbound, t.oid)
              )
              ORDER BY CASE WHEN t.relkind = 'p' THEN 0 ELSE 1 END::int, t.relispartition
           ), '{}'::jsonb[])
      INTO table_objects
      FROM pg_class t
      LEFT
      JOIN pg_inherits h
        ON h.inhrelid = t.oid
      LEFT
      JOIN pg_partitioned_table pt
        ON pt.partrelid = h.inhparent
      LEFT
      JOIN pg_class p
        ON p.oid = pt.partrelid
      LEFT
      JOIN pg_partitioned_table pt2
        ON pt2.partrelid = t.oid
      LEFT
      JOIN pg_attribute pk
        ON pk.attrelid = t.oid
       AND pk.attnum = pt2.partattrs::text::int2
     WHERE t.relnamespace = source_schema::regnamespace
       AND t.relkind in ('r', 'p');

    IF _verbose THEN
        RAISE INFO '    Got %s table objects...', cardinality(table_objects);
    END IF;

    /* Foreign Key objects */
    IF _verbose THEN
        RAISE INFO 'Gathering foreign key constraint data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'table_name', rn.relname,
                   'constraint_name', ct.conname,
                   'alter_stmt', 'ALTER TABLE ' || quote_ident(rn.relname) ||
                                     ' ADD CONSTRAINT ' || quote_ident(ct.conname) || ' ' ||
                                     replace(pg_get_constraintdef(ct.oid), source_schema || '.', '') ||
                                     ' ;'
               )
           ), '{}'::jsonb[])
    INTO fk_objects
    FROM pg_constraint ct
    JOIN pg_class rn
        ON rn.oid = ct.conrelid
    WHERE connamespace = source_schema::regnamespace
    AND rn.relkind in ('r', 'p')
    AND NOT rn.relispartition
    AND ct.contype = 'f';

    IF _verbose THEN
        RAISE INFO '    Got %s foreign key objects...', cardinality(fk_objects);
    END IF;

    /* View objects */
    IF _verbose THEN
        RAISE INFO 'Gathering view object data from %...', source_schema;
    END IF;

    WITH RECURSIVE view_deps as (
    SELECT DISTINCT
           0 as depth,
           v.oid as view_oid,
           v.relname::text as view_name,
           v.relkind as view_kind,
           v.oid as dep_obj_id,
           v.relname::text as dep_obj_name,
           v.relkind as deb_obj_kind
      FROM pg_class v
     WHERE v.relnamespace = source_schema::regnamespace
       AND v.relkind IN ('v', 'm')
       AND NOT EXISTS (
                        SELECT 1 as x
                          FROM pg_depend d
                          JOIN pg_class c
                            ON c.oid = d.objid
                           AND c.relkind in ('m', 'v')
                         WHERE d.refobjid = v.oid
                      )
     UNION
    SELECT DISTINCT
           rv.depth + 1 as "depth",
           dv.oid as view_oid,
           dv.relname as view_name,
           dv.relkind as view_kind,
           rv.view_oid as ref_view_oid,
           rv.view_name as ref_view_name,
           rv.view_kind as ref_view_kind
      FROM pg_class dv
      JOIN pg_depend pd
        ON pd.objid = dv.oid
      JOIN view_deps as rv
        ON rv.view_oid = pd.refobjid
     WHERE dv.relnamespace = source_schema::regnamespace
       AND dv.relkind in ('m', 'v')
    ),
    base_view_def as (
    SELECT *,
           replace(pg_get_viewdef(view_oid), source_schema || '.', '') as "view_def"
      FROM view_deps
    )
    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'view_name', bvd.view_name,
                   'depth', bvd.depth,
                   'view_kind', CASE WHEN bvd.view_kind = 'm'
                                          THEN 'MATERIALIZED VIEW'
                                     ELSE 'VIEW'
                                END::text,
                   'view_def', CASE WHEN bvd.view_kind = 'm'
                                         THEN substr(bvd.view_def, 1, length(bvd.view_def) - 1) || ' WITH DATA;'
                                    ELSE bvd.view_def
                               END::text,
                   'view_indexes', COALESCE((SELECT to_jsonb(array_to_json(array_agg(replace(pg_get_indexdef(i.indexrelid),
                                                                                     source_schema || '.',
                                                                                     ''))))
                                               FROM pg_index i
                                              WHERE i.indrelid = bvd.view_oid),
                                            jsonb_build_array())
               )
               order by bvd.depth
           ), '{}'::jsonb[])
      INTO view_objects
      FROM base_view_def bvd;

    IF _verbose THEN
        RAISE INFO '    Got %s view objects...', cardinality(view_objects);
    END IF;

    /* Function objects */
    IF _verbose THEN
        RAISE INFO 'Gathering function/procedure object data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'func_name', proname,
                   'func_type', CASE prokind
                                     WHEN 'p' THEN 'PROCEDURE'
                                     WHEN 'f' THEN 'FUNCTION'
                                     WHEN 'a' THEN 'AGGREGATE'
                                     WHEN 'w' THEN 'WINDOW'
                                     ELSE 'UNKNOWN'
                                END::text,
                   'func_stmt', replace(pg_get_functiondef(oid), source_schema || '.', '')
               )
           ), '{}'::jsonb[])
    INTO function_objects
    FROM pg_proc
    WHERE pronamespace = source_schema::regnamespace;

    IF _verbose THEN
        RAISE INFO '    Got %s function/procedure objects...', cardinality(function_objects);
    END IF;

    /* Trigger objects */
    IF _verbose THEN
        RAISE INFO 'Gathering trigger object data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'trigger_id', t.oid,
                   'trigger_name', t.tgname::text,
                   'table_name', c.relname::text,
                   'trigger_def', replace(pg_get_triggerdef(t.oid), source_schema || '.', '')
               )
           ), '{}'::jsonb[])
      INTO trigger_objects
      FROM pg_trigger t
      JOIN pg_class c
        ON c.oid = t.tgrelid
       AND NOT c.relispartition
     WHERE c.relnamespace = source_schema::regnamespace
       AND t.tgconstraint = 0;

    IF _verbose THEN
        RAISE INFO '    Got %s trigger objects...', cardinality(trigger_objects);
    END IF;

    /* Rule objects */
    IF _verbose THEN
        RAISE INFO 'Gathering rule object data from %...', source_schema;
    END IF;

    SELECT coalesce(array_agg(
               jsonb_build_object(
                   'tablename', tablename,
                   'rulename', rulename,
                   'rule_def', replace(definition, source_schema || '.', '')
               )
           ), '{}'::jsonb[])
    INTO rule_objects
    FROM pg_rules
    WHERE schemaname = source_schema;

    IF _verbose THEN
        RAISE INFO '    Got %s rule objects...', cardinality(rule_objects);
    END IF;

    /* Comment objects */
    IF _verbose THEN
        RAISE INFO 'Gathering object comment data from %...', source_schema;
    END IF;

    select coalesce(array_agg(
               jsonb_build_object(
                   'oid', t.oid,
                   'attnum', coalesce(c.attnum, -1),
                   'relkind', t.relkind,
                   'table_name', quote_ident(t.relname::text),
                   'dot', case when c.attname is not null then '.' else '' end::text,
                   'column_name', case when c.attname is not null then quote_ident(c.attname) else '' end::text,
                   'comment_type', case when c.attname is null
                                             then case t.relkind
                                                       when 'm' then 'MATERIALIZED VIEW'
                                                       when 'v' then 'VIEW'
                                                       else 'TABLE'
                                                  end::text
                                        else 'COLUMN'
                                   end::text,
                   'description', d.description
               )
               order by t.oid, coalesce(c.attnum, -1)
           ), '{}'::jsonb[])
      into comment_objects
      from pg_description d
      join pg_class t
        on t.oid = d.objoid
      left
      join pg_attribute c
        on c.attrelid = t.oid
       and c.attnum = d.objsubid
     where t.relnamespace = source_schema::regnamespace
       and t.relkind = any('{r,p,v,m}'::text[]);

    IF _verbose THEN
        RAISE INFO '    Got %s comment objects...', cardinality(comment_objects);
    END IF;

    RETURN jsonb_build_object('sequence_data', sequence_objects,
                              'table_data', table_objects,
                              'sequence_owner_data', sequence_owner_info,
                              'foreign_key_data', fk_objects,
                              'view_data', view_objects,
                              'function_data', function_objects,
                              'trigger_data', trigger_objects,
                              'rule_data', rule_objects,
                              'comment_data', comment_objects);
END;
$$ LANGUAGE plpgsql;

/*
 * =======================================
 * =======================================
 */

DROP FUNCTION IF EXISTS public.create_schema(text, jsonb, text[], boolean, boolean);
CREATE OR REPLACE FUNCTION public.create_schema(
    source_schema text,
    source_structure jsonb,
    new_schemata text[],
    copy_data boolean DEFAULT false,
    _verbose boolean DEFAULT false
) RETURNS text[] AS $$
DECLARE
    jobject jsonb;
    src_schema text;
    dst_schema text;
    dest_obj text;
    ix_stmt text;
    seq_start int;
    dest_schema_exists oid;
    completed_schemata text[];
BEGIN
    FOREACH dest_schema IN ARRAY new_schemata
    LOOP
        dst_schema = quote_ident(dest_schema);
        src_schema = quote_ident(source_schema);

        /* Check if dest schema exists */
        SELECT oid
          INTO dest_schema_exists
          FROM pg_namespace
         WHERE nspname = dest_schema;
        IF dest_schema_exists IS NOT NULL
        THEN
            RAISE INFO 'Destination schema % already exists.', dst_schema;
        END IF;

        CONTINUE WHEN dest_schema_exists IS NOT NULL;

        /*
         * Create the new schema
         */
        IF _verbose
        THEN
            RAISE INFO 'Creating schema %', dst_schema;
        END IF;
        EXECUTE FORMAT('CREATE SCHEMA %I ;', dest_schema);

        EXECUTE FORMAT('SET LOCAL search_path = %I, public ;', dest_schema);

        /*
         * Create sequences
         */

        IF jsonb_array_length(source_structure->'sequence_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Creating sequences for %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'sequence_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    %.%', dst_schema, quote_ident(jobject->>'sequence_name');
                END IF;

                IF copy_data OR
                   (jobject->>'sequence_name' ~ 'partitioned_tables'::text) OR
                   (jobject->>'sequence_name' ~ 'django_migrations'::text)
                THEN
                    seq_start = coalesce((jobject->'sequence_last_value')::int + 1, (jobject->>'sequence_start')::int)
                END IF;

                EXECUTE FORMAT('CREATE SEQUENCE IF NOT EXISTS %I AS %s START WITH %s INCREMENT BY %s MINVALUE %s MAXVALUE %s CACHE %s %s ;',
                            jobject->>'sequence_name'::text,
                            jobject->>'sequence_type'::text,
                            seq_start::int,
                            (jobject->>'sequence_inc')::int,
                            (jobject->>'sequence_min')::int,
                            (jobject->>'sequence_max')::int,
                            (jobject->>'sequence_cache')::int,
                            jobject->>'sequence_cycle'::text);
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No sequences for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create tables
         */
        IF jsonb_array_length(source_structure->'table_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Creating tables for %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'table_data')
            LOOP
                dest_obj = dst_schema || '.' || quote_ident(jobject->>'table_name'::text);

                IF jobject->>'table_kind' = 'p'::text
                THEN
                    IF _verbose
                    THEN
                        RAISE INFO '    % (partitioned table)', dest_obj;
                    END IF;
                    EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I (LIKE %I.%I INCLUDING ALL) PARTITION BY %s ( %I ) ;',
                                jobject->>'table_name'::text,
                                source_schema,
                                jobject->>'table_name'::text,
                                jobject->>'partition_type'::text,
                                jobject->>'partition_key'::text);
                ELSIF (jobject->>'is_partition'::text):: boolean
                THEN
                    IF _verbose
                    THEN
                        RAISE INFO '    % (table partition)', dest_obj;
                    END IF;
                    EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I %s ;',
                                jobject->>'table_name'::text,
                                jobject->>'partitioned_table'::text,
                                jobject->>'partition_expr'::text);
                ELSE
                    IF _verbose
                    THEN
                        RAISE INFO '    % (table)', dest_obj;
                    END IF;
                    EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I (LIKE %I.%I INCLUDING ALL) ;',
                                jobject->>'table_name'::text,
                                source_schema,
                                jobject->>'table_name'::text);
                END IF;

                IF (copy_data OR
                    (jobject->>'table_name' ~ 'partitioned_tables'::text) OR
                    (jobject->>'table_name' ~ 'django_migrations'::text)) AND
                (jobject->>'table_kind' = 'r'::text)
                THEN
                    IF _verbose
                    THEN
                        RAISE INFO '        Copying data...';
                    END IF;
                    EXECUTE FORMAT('INSERT INTO %I SELECT * FROM %I.%I ;',
                                jobject->>'table_name'::text,
                                source_schema,
                                jobject->>'table_name'::text);
                END IF;

                IF jobject->>'table_name' = 'partitioned_tables'::text
                THEN
                    IF _verbose
                    THEN
                        RAISE INFO '        Update partitioned_tables schema data';
                    END IF;
                    EXECUTE 'UPDATE partitioned_tables SET schema_name = current_schema ;';
                END IF;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No tables for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create sequence owner links
         */
        IF jsonb_array_length(source_structure->'sequence_owner_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Setting sequence ownership for objects in %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'sequence_owner_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    Update primary key default for %.%', dst_schema, quote_ident(jobject->>'owner_object'::text);
                END IF;
                EXECUTE FORMAT('ALTER TABLE %I ALTER COLUMN %I SET DEFAULT nextval( ''%I''::regclass );',
                            jobject->>'owner_object'::text,
                            jobject->>'owner_column'::text,
                            jobject->>'sequence_name'::text);

                IF _verbose
                THEN
                    RAISE INFO '    Update sequence owned-by table column to %."%"', dest_obj, jobject->>'owner_column'::text;
                END IF;
                EXECUTE FORMAT('ALTER SEQUENCE %I OWNED BY %I.%I ;',
                            jobject->>'sequence_name'::text,
                            jobject->>'owner_object'::text,
                            jobject->>'owner_column'::text);
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No sequence owner data for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create Foreign Key Constraints
         */
        IF jsonb_array_length(source_structure->'foreign_key_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Create foriegn key constraints for tables in "%"', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'foreign_key_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    %.%', jobject->>'table_name', jobject->>'constraint_name'::text;
                END IF;
                EXECUTE jobject->>'alter_stmt'::text;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No foreign key constraints for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create Views
         */
        IF jsonb_array_length(source_structure->'view_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Creating views for %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'view_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    %: "%"', jobject->>'view_kind', jobject->>'view_name'::text;
                END IF;
                EXECUTE FORMAT('CREATE %s %I AS %s',
                            jobject->>'view_kind'::text,
                            jobject->>'view_name'::text,
                            jobject->>'view_def'::text);

                IF jsonb_array_length(jobject->'view_indexes') > 0
                THEN
                    IF _verbose
                    THEN
                        RAISE INFO '        Create indexes';
                    END IF;
                    FOR ix_stmt IN select jsonb_array_elements_text(jobject->'view_indexes')
                    LOOP
                        EXECUTE ix_stmt;
                    END LOOP;
                END IF;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No view objects for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create functions
         */
        IF jsonb_array_length(source_structure->'function_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Create functions, procedures for "%"', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'function_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    "%" "%"', jobject->>'func_type', jobject->>'func_name'::text;
                END IF;
                EXECUTE jobject->>'func_stmt'::text;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No function/procedure objects for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create triggers
         */
        IF jsonb_array_length(source_structure->'trigger_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Create triggers on objects in "%"', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'trigger_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    "%"."%"', jobject->>'table_name', jobject->>'trigger_name'::text;
                END IF;
                EXECUTE jobject->>'trigger_def'::text;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No trigger objects for %', dst_schema;
            END IF;
        END IF;

        /*
         *  Create rules
         */
        IF jsonb_array_length(source_structure->'rule_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Creating rules on objects in %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'rule_data')
            LOOP
                IF _verbose
                THEN
                    RAISE INFO '    RULE "%" on "%"', jobject->>'rulename', jobject->>'tablename'::text;
                END IF;
                EXECUTE jobject->>'rule_def'::text;
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No rule objects for %', dst_schema;
            END IF;
        END IF;

        /*
         * Create comments
         */
        IF jsonb_array_length(source_structure->'comment_data') > 0
        THEN
            IF _verbose
            THEN
                RAISE INFO 'Creating comments on objects in %', dst_schema;
            END IF;
            FOR jobject IN SELECT jsonb_array_elements(source_structure->'comment_data')
            LOOP
                IF _verbose AND ((jobject->>'attnum')::int = -1)
                THEN
                    RAISE INFO '    % % %', jobject->>'comment_type', jobject->>'table_name', jobject->>'column_name';
                END IF;
                EXECUTE FORMAT('COMMENT ON %s %s.%s%s%s IS %L ;',
                            jobject->>'comment_type'::text,
                            dst_schema,
                            jobject->>'table_name',
                            jobject->>'dot',
                            jobject->>'column_name'::text,
                            jobject->>'description'::text);
            END LOOP;
        ELSE
            IF _verbose
            THEN
                RAISE INFO 'No comments on objects for %', dst_schema;
            END IF;
        END IF;

        /*
         * Mark that the dest_schema object creation has been successful
         */
        array_append(completed_schemata, dest_schema);
    END LOOP; -- new schema loop end

    RETURN completed_schemata;
END;
$$ LANGUAGE plpgsql;
