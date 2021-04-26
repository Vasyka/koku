
WITH cte_tag_value AS (
    SELECT key,
        value,
        li.cost_entry_bill_id,
        li.subscription_guid
    FROM {{schema | sqlsafe}}.reporting_azurecostentrylineitem_daily_summary AS li,
        jsonb_each_text(li.tags) labels
    WHERE li.usage_start >= {{start_date}}
        AND li.usage_start <= {{end_date}}
    {% if bill_ids %}
        AND li.cost_entry_bill_id IN (
        {%- for bill_id in bill_ids -%}
        {{bill_id}}{% if not loop.last %},{% endif %}
        {%- endfor -%}
    )
    {% endif %}
    GROUP BY key, value, li.cost_entry_bill_id, li.subscription_guid
),
cte_values_agg AS (
    SELECT key,
        array_agg(DISTINCT value) as "values",
        cost_entry_bill_id,
        subscription_guid
    FROM cte_tag_value
    GROUP BY key, cost_entry_bill_id, subscription_guid
),
cte_distinct_values_agg AS (
    SELECT v.key,
        array_agg(DISTINCT v."values") as "values",
        v.cost_entry_bill_id,
        v.subscription_guid
    FROM (
        SELECT va.key,
            unnest(va."values" || coalesce(ls."values", '{}'::text[])) as "values",
            va.cost_entry_bill_id,
            va.subscription_guid
        FROM cte_values_agg AS va
        LEFT JOIN {{schema | sqlsafe}}.reporting_azuretags_summary AS ls
            ON va.key = ls.key
                AND va.cost_entry_bill_id = ls.cost_entry_bill_id
                AND va.subscription_guid = ls.subscription_guid
    ) as v
    GROUP BY key, cost_entry_bill_id, subscription_guid
),
ins1 AS (
    INSERT INTO {{schema | sqlsafe}}.reporting_azuretags_summary (uuid, key, cost_entry_bill_id, subscription_guid, values)
    SELECT uuid_generate_v4() as uuid,
        key,
        cost_entry_bill_id,
        subscription_guid,
        "values"
    FROM cte_distinct_values_agg
    ON CONFLICT (key, cost_entry_bill_id, subscription_guid) DO UPDATE SET values=EXCLUDED."values"
)
INSERT INTO {{schema | sqlsafe}}.reporting_azuretags_values (uuid, key, value, subscription_guids)
SELECT uuid_generate_v4() as uuid,
    tv.key,
    tv.value,
    array_agg(DISTINCT tv.subscription_guid) as subscription_guids
FROM cte_tag_value AS tv
GROUP BY tv.key, tv.value
ON CONFLICT (key, value) DO UPDATE SET subscription_guids=EXCLUDED.subscription_guids
;
