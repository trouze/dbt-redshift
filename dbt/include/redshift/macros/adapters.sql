
{% macro dist(dist) %}
  {%- if dist is not none -%}
      {%- set dist = dist.strip().lower() -%}

      {%- if dist in ['all', 'even'] -%}
        diststyle {{ dist }}
      {%- elif dist == "auto" -%}
      {%- else -%}
        diststyle key distkey ({{ dist }})
      {%- endif -%}

  {%- endif -%}
{%- endmacro -%}


{% macro sort(sort_type, sort) %}
  {%- if sort is not none %}
      {{ sort_type | default('compound', boolean=true) }} sortkey(
      {%- if sort is string -%}
        {%- set sort = [sort] -%}
      {%- endif -%}
      {%- for item in sort -%}
        {{ item }}
        {%- if not loop.last -%},{%- endif -%}
      {%- endfor -%}
      )
  {%- endif %}
{%- endmacro -%}


{% macro redshift__create_table_as(temporary, relation, sql) -%}

  {%- set _dist = config.get('dist') -%}
  {%- set _sort_type = config.get(
          'sort_type',
          validator=validation.any['compound', 'interleaved']) -%}
  {%- set _sort = config.get(
          'sort',
          validator=validation.any[list, basestring]) -%}
  {%- set sql_header = config.get('sql_header', none) -%}
  {%- set backup = config.get('backup') -%}

  {{ sql_header if sql_header is not none }}

  {%- if config.get('contract', False) %}

  create {% if temporary -%}temporary{%- endif %} table
    {{ relation.include(database=(not temporary), schema=(not temporary)) }}
    {{ get_columns_spec_ddl() }}
    {{ get_assert_columns_equivalent(sql) }}
    {%- set sql = get_select_subquery(sql) %}
    {% if backup == false -%}backup no{%- endif %}
    {{ dist(_dist) }}
    {{ sort(_sort_type, _sort) }}
  ;

  insert into {{ relation.include(database=(not temporary), schema=(not temporary)) }}
    (
      {{ sql }}
    )
  ;

  {%- else %}

  create {% if temporary -%}temporary{%- endif %} table
    {{ relation.include(database=(not temporary), schema=(not temporary)) }}
    {% if backup == false -%}backup no{%- endif %}
    {{ dist(_dist) }}
    {{ sort(_sort_type, _sort) }}
  as (
    {{ sql }}
  );

  {%- endif %}
{%- endmacro %}


{% macro redshift__create_view_as(relation, sql) -%}
  {%- set binding = config.get('bind', default=True) -%}

  {% set bind_qualifier = '' if binding else 'with no schema binding' %}
  {%- set sql_header = config.get('sql_header', none) -%}

  {{ sql_header if sql_header is not none }}

  create view {{ relation }}
  {% if config.get('contract', False) -%}
    {{ get_assert_columns_equivalent(sql) }}
  {%- endif %} as (
    {{ sql }}
  ) {{ bind_qualifier }};
{% endmacro %}


{% macro redshift__create_schema(relation) -%}
  {{ postgres__create_schema(relation) }}
{% endmacro %}


{% macro redshift__drop_schema(relation) -%}
  {{ postgres__drop_schema(relation) }}
{% endmacro %}


{% macro redshift__get_columns_in_relation(relation) -%}
  {% call statement('get_columns_in_relation', fetch_result=True) %}
      with bound_views as (
        select
          ordinal_position,
          table_schema,
          column_name,
          data_type,
          character_maximum_length,
          numeric_precision,
          numeric_scale

        from information_schema."columns"
        where table_name = '{{ relation.identifier }}'
    ),

    unbound_views as (
      select
        ordinal_position,
        view_schema,
        col_name,
        case
          when col_type ilike 'character varying%' then
            'character varying'
          when col_type ilike 'numeric%' then 'numeric'
          else col_type
        end as col_type,
        case
          when col_type like 'character%'
          then nullif(REGEXP_SUBSTR(col_type, '[0-9]+'), '')::int
          else null
        end as character_maximum_length,
        case
          when col_type like 'numeric%'
          then nullif(
            SPLIT_PART(REGEXP_SUBSTR(col_type, '[0-9,]+'), ',', 1),
            '')::int
          else null
        end as numeric_precision,
        case
          when col_type like 'numeric%'
          then nullif(
            SPLIT_PART(REGEXP_SUBSTR(col_type, '[0-9,]+'), ',', 2),
            '')::int
          else null
        end as numeric_scale

      from pg_get_late_binding_view_cols()
      cols(view_schema name, view_name name, col_name name,
           col_type varchar, ordinal_position int)
      where view_name = '{{ relation.identifier }}'
    ),

    external_views as (
      select
        columnnum,
        schemaname,
        columnname,
        case
          when external_type ilike 'character varying%' or external_type ilike 'varchar%'
          then 'character varying'
          when external_type ilike 'numeric%' then 'numeric'
          else external_type
        end as external_type,
        case
          when external_type like 'character%' or external_type like 'varchar%'
          then nullif(
            REGEXP_SUBSTR(external_type, '[0-9]+'),
            '')::int
          else null
        end as character_maximum_length,
        case
          when external_type like 'numeric%'
          then nullif(
            SPLIT_PART(REGEXP_SUBSTR(external_type, '[0-9,]+'), ',', 1),
            '')::int
          else null
        end as numeric_precision,
        case
          when external_type like 'numeric%'
          then nullif(
            SPLIT_PART(REGEXP_SUBSTR(external_type, '[0-9,]+'), ',', 2),
            '')::int
          else null
        end as numeric_scale
      from
        pg_catalog.svv_external_columns
      where
        schemaname = '{{ relation.schema }}'
        and tablename = '{{ relation.identifier }}'

    ),

    unioned as (
      select * from bound_views
      union all
      select * from unbound_views
      union all
      select * from external_views
    )

    select
      column_name,
      data_type,
      character_maximum_length,
      numeric_precision,
      numeric_scale

    from unioned
    {% if relation.schema %}
    where table_schema = '{{ relation.schema }}'
    {% endif %}
    order by ordinal_position
  {% endcall %}
  {% set table = load_result('get_columns_in_relation').table %}
  {{ return(sql_convert_columns_in_relation(table)) }}
{% endmacro %}


{% macro redshift__list_relations_without_caching(schema_relation) %}
  {{ return(postgres__list_relations_without_caching(schema_relation)) }}
{% endmacro %}


{% macro redshift__information_schema_name(database) -%}
  {{ return(postgres__information_schema_name(database)) }}
{%- endmacro %}


{% macro redshift__list_schemas(database) -%}
  {{ return(postgres__list_schemas(database)) }}
{%- endmacro %}


{% macro redshift__check_schema_exists(information_schema, schema) -%}
  {{ return(postgres__check_schema_exists(information_schema, schema)) }}
{%- endmacro %}


{% macro redshift__persist_docs(relation, model, for_relation, for_columns) -%}
  {% if for_relation and config.persist_relation_docs() and model.description %}
    {% do run_query(alter_relation_comment(relation, model.description)) %}
  {% endif %}

  {# Override: do not set column comments for LBVs #}
  {% set is_lbv = config.get('materialized') == 'view' and config.get('bind') == false %}
  {% if for_columns and config.persist_column_docs() and model.columns and not is_lbv %}
    {% do run_query(alter_column_comment(relation, model.columns)) %}
  {% endif %}
{% endmacro %}


{% macro redshift__alter_relation_comment(relation, comment) %}
  {% do return(postgres__alter_relation_comment(relation, comment)) %}
{% endmacro %}


{% macro redshift__alter_column_comment(relation, column_dict) %}
  {% do return(postgres__alter_column_comment(relation, column_dict)) %}
{% endmacro %}


{% macro get_current_query_tag() -%}
  {{ return(run_query("show query_group").rows[0]['query_group']) }}
{% endmacro %}


{% macro redshift__set_query_tag() -%}
  {% set new_query_tag = config.get('query_tag') %}
  {% if new_query_tag %}
    {% set original_query_tag = get_current_query_tag() %}
    {{ log("Setting query_tag to '" ~ new_query_tag ~ "'. Will reset to '" ~ original_query_tag ~ "' after materialization.") }}
    {% do run_query("set query_group to '{}'".format(new_query_tag)) %}
    {{ return(original_query_tag)}}
  {% endif %}
  {{ return(none)}}
{% endmacro %}


{% macro redshift__unset_query_tag(original_query_tag) -%}
  {% set new_query_tag = config.get('query_tag') %}
  {% if new_query_tag %}
    {% if original_query_tag %}
      {{ log("Resetting query_tag to '" ~ original_query_tag ~ "'.") }}
      {% do run_query("set query_group to '{}'".format(original_query_tag)) %}
    {% else %}
      {{ log("No original query_tag, unsetting parameter.") }}
      {% do run_query("reset query_group") %}
    {% endif %}
  {% endif %}
{% endmacro %}


{% macro redshift__alter_relation_add_remove_columns(relation, add_columns, remove_columns) %}

  {% if add_columns %}

    {% for column in add_columns %}
      {% set sql -%}
          alter {{ relation.type }} {{ relation }} add column {{ column.name }} {{ column.data_type }}
      {% endset %}
      {% do run_query(sql) %}
    {% endfor %}

  {% endif %}

  {% if remove_columns %}

    {% for column in remove_columns %}
      {% set sql -%}
          alter {{ relation.type }} {{ relation }} drop column {{ column.name }}
      {% endset %}
      {% do run_query(sql) %}
    {% endfor %}

  {% endif %}

{% endmacro %}
