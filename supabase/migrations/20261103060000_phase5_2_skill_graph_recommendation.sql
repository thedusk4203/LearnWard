-- =============================================================================
-- LearnWard Phase 5.2 Migration
-- Skill Graph Traversal, Freshness Engine v0.1, Recovery Engine v0.1,
-- Next Challenge Engine v0.1, Coverage-Aware Learning Overview & Node State
-- =============================================================================
-- Authoritative Design:
--   - docs/14-phase-5-2-dependency-readiness-review.md
--   - docs/15-phase-5-2-skill-graph-recommendation-design-v0.1.md
--   - docs/adr/0007-phase-5-2-skill-graph-recommendation.md (PROPOSED)
--
-- Strict Invariants:
--   1. Pure read-time projections only (zero new tables; zero writes on read).
--   2. Consumes frozen Phase 5.1 Mastery & Confidence semantics at server-authoritative as_of:
--      - Confidence uses exact Phase 5.1 60-day effective_occurred_at window [as_of - 60d, as_of].
--      - Sticky mastery_attained_at <= as_of is the sole route to mastery_band = 'mastered'.
--   3. Phase 5.2 direct-evidence derivations (Recovery, latest_evidence, Freshness) enforce
--      dual temporal visibility: effective_occurred_at <= as_of AND verified_at <= as_of.
--   4. Published pilot-v0.1 catalog and frozen Phase 1-5.1 objects remain untouched.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. INTERNAL HELPER: Deterministic Recovery Engine v0.1 Replay
-- ---------------------------------------------------------------------------

create or replace function private.evaluate_node_recovery_at(
  p_child_id uuid,
  p_learning_node_id uuid,
  p_node_type text,
  p_as_of timestamptz,
  out recovery_signal text,
  out latest_unresolved_weakness_at timestamptz
)
returns record
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ev record;
  v_state text := 'none';
  v_latest_weak_at timestamptz := null;
begin
  -- Recovery applies ONLY to topic and skill nodes
  if p_node_type is null or p_node_type not in ('topic', 'skill') then
    recovery_signal := 'none';
    latest_unresolved_weakness_at := null;
    return;
  end if;

  -- Replay visible component_score and item_group evidence in canonical chronology order
  for v_ev in
    select
      ev.score_source,
      ev.performance_pct,
      ev.item_count,
      ev.correct_count,
      ev.effective_occurred_at
    from public.learning_evidence_events ev
    where ev.child_id = p_child_id
      and ev.learning_node_id = p_learning_node_id
      and ev.score_source in ('component_score', 'item_group')
      and ev.effective_occurred_at <= p_as_of
      and ev.verified_at <= p_as_of
    order by
      ev.effective_occurred_at asc,
      ev.verified_at asc,
      ev.verified_learning_event_id asc
  loop
    if (
      v_ev.score_source = 'item_group'
      and v_ev.performance_pct < 70
      and v_ev.item_count is not null
      and v_ev.correct_count is not null
      and v_ev.item_count >= 3
      and (v_ev.item_count - v_ev.correct_count) >= 2
    ) or (
      v_ev.score_source = 'component_score'
      and v_ev.performance_pct <= 50
    ) then
      v_state := 'review_suggested';
      v_latest_weak_at := v_ev.effective_occurred_at;
    elsif v_ev.performance_pct >= 70 then
      v_state := 'none';
      v_latest_weak_at := null;
    end if;
  end loop;

  if v_state = 'review_suggested'
     and v_latest_weak_at is not null
     and (p_as_of - v_latest_weak_at) <= interval '30 days' then
    recovery_signal := 'review_suggested';
    latest_unresolved_weakness_at := v_latest_weak_at;
  else
    recovery_signal := 'none';
    latest_unresolved_weakness_at := null;
  end if;
end;
$$;

revoke all on function private.evaluate_node_recovery_at(uuid, uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. INTERNAL HELPER: private.get_child_learning_overview_at
-- ---------------------------------------------------------------------------

create or replace function private.get_child_learning_overview_at(
  p_child_id uuid,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_as_of timestamptz;
  v_child record;
  v_active_version text;
  v_overall_coverage jsonb;
  v_subjects jsonb;
begin
  v_as_of := coalesce(p_as_of, transaction_timestamp());

  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  with active_subjects as (
    select
      r.id as learning_node_id,
      r.id as subject_node_id,
      r.catalog_version,
      r.node_type,
      r.subject_key,
      r.canonical_key,
      r.title,
      r.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      r.grade_min,
      r.grade_max,
      r.sort_order,
      array[r.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes r
    where r.catalog_version = v_active_version
      and r.node_type = 'subject'
      and r.is_active = true
  ),
  active_domains as (
    select
      d.id as learning_node_id,
      r.subject_node_id,
      d.catalog_version,
      d.node_type,
      d.subject_key,
      d.canonical_key,
      d.title,
      d.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      d.grade_min,
      d.grade_max,
      d.sort_order,
      array[r.sort_order, d.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes d
    join active_subjects r on r.learning_node_id = d.parent_id
    where d.catalog_version = v_active_version
      and d.node_type = 'domain'
      and d.is_active = true
  ),
  active_topics as (
    select
      t.id as learning_node_id,
      d.subject_node_id,
      t.catalog_version,
      t.node_type,
      t.subject_key,
      t.canonical_key,
      t.title,
      t.parent_id,
      d.learning_node_id as parent_domain_id,
      d.title as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      t.grade_min,
      t.grade_max,
      t.sort_order,
      (d.catalog_sort_path || t.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes t
    join active_domains d on d.learning_node_id = t.parent_id
    where t.catalog_version = v_active_version
      and t.node_type = 'topic'
      and t.is_active = true
  ),
  active_skills as (
    select
      s.id as learning_node_id,
      t.subject_node_id,
      s.catalog_version,
      s.node_type,
      s.subject_key,
      s.canonical_key,
      s.title,
      s.parent_id,
      t.parent_domain_id,
      t.parent_domain_title,
      t.learning_node_id as parent_topic_id,
      t.title as parent_topic_title,
      s.grade_min,
      s.grade_max,
      s.sort_order,
      (t.catalog_sort_path || s.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes s
    join active_topics t on t.learning_node_id = s.parent_id
    where s.catalog_version = v_active_version
      and s.node_type = 'skill'
      and s.is_active = true
  ),
  universe as (
    select * from active_subjects
    union all
    select * from active_domains
    union all
    select * from active_topics
    union all
    select * from active_skills
  ),
  node_states as (
    select
      u.*,
      (cms.learning_node_id is not null) as is_observed,
      cms.mastery_score,
      cms.effective_evidence_count,
      cms.distinct_assessment_count,
      cms.mastery_attained_at,
      case
        when cms.learning_node_id is null then null
        when cms.mastery_attained_at is not null and cms.mastery_attained_at <= v_as_of then 'mastered'
        when cms.mastery_score >= 85 then 'mastery_candidate'
        when cms.mastery_score >= 70 then 'secure'
        when cms.mastery_score >= 50 then 'developing'
        else 'emerging'
      end as mastery_band,
      case
        when cms.learning_node_id is null then null
        else conf.band
      end as confidence_band,
      case
        when cms.learning_node_id is null then 0.00::numeric(5,2)
        else conf.units
      end as confidence_units,
      case
        when cms.learning_node_id is null then 0
        else conf.distinct_recent_vles
      end as distinct_recent_vle_count,
      vis.latest_effective_occurred_at,
      case
        when cms.learning_node_id is null or vis.latest_effective_occurred_at is null then 'unknown'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '14 days' then 'recent'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '45 days' then 'aging'
        else 'needs_refresh'
      end as freshness,
      case
        when cms.learning_node_id is null then 'none'
        else rec.recovery_signal
      end as recovery_signal,
      case
        when cms.learning_node_id is null then null
        else rec.latest_unresolved_weakness_at
      end as latest_unresolved_weakness_at,
      case
        when u.grade_min is null and u.grade_max is null then true
        when v_child.school_grade is null then false
        else (u.grade_min is null or v_child.school_grade >= u.grade_min)
         and (u.grade_max is null or v_child.school_grade <= u.grade_max)
      end as is_grade_compatible,
      coalesce(prereq.prerequisite_count, 0) as prerequisite_count,
      coalesce(prereq.attained_prerequisite_count, 0) as attained_prerequisite_count,
      coalesce(prereq.is_prerequisite_satisfied, true) as is_prerequisite_satisfied
    from universe u
    left join public.child_mastery_states cms
      on cms.child_id = p_child_id
     and cms.learning_node_id = u.learning_node_id
    cross join lateral (
      select
        coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00)::numeric(5,2) as units,
        count(distinct ev.verified_learning_event_id)::integer as distinct_recent_vles,
        case
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) > 3.50
               and count(distinct ev.verified_learning_event_id) >= 2 then 'high'
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) >= 1.50 then 'medium'
          else 'low'
        end as band
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at >= v_as_of - interval '60 days'
        and ev.effective_occurred_at <= v_as_of
    ) conf
    cross join lateral (
      select max(ev.effective_occurred_at) as latest_effective_occurred_at
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at <= v_as_of
        and ev.verified_at <= v_as_of
    ) vis
    cross join lateral private.evaluate_node_recovery_at(
      p_child_id,
      u.learning_node_id,
      case when cms.learning_node_id is not null then u.node_type else null end,
      v_as_of
    ) rec
    left join lateral (
      select
        count(*)::integer as prerequisite_count,
        count(*) filter (
          where p_u.learning_node_id is not null
            and cms_p.mastery_attained_at is not null
            and cms_p.mastery_attained_at <= v_as_of
        )::integer as attained_prerequisite_count,
        (
          count(*) = count(*) filter (
            where p_u.learning_node_id is not null
              and cms_p.mastery_attained_at is not null
              and cms_p.mastery_attained_at <= v_as_of
          )
        ) as is_prerequisite_satisfied
      from public.learning_prerequisites lp
      left join active_skills p_u on p_u.learning_node_id = lp.prerequisite_node_id
      left join public.child_mastery_states cms_p
        on cms_p.child_id = p_child_id
       and cms_p.learning_node_id = lp.prerequisite_node_id
      where u.node_type = 'skill'
        and lp.catalog_version = v_active_version
        and lp.dependent_node_id = u.learning_node_id
    ) prereq on true
  ),
  overall_cov as (
    select jsonb_build_object(
      'total_topics', count(*) filter (where ns.node_type = 'topic'),
      'observed_topics', count(*) filter (where ns.node_type = 'topic' and ns.is_observed),
      'unseen_topics', count(*) filter (where ns.node_type = 'topic' and not ns.is_observed),
      'total_skills', count(*) filter (where ns.node_type = 'skill'),
      'observed_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed),
      'unseen_skills', count(*) filter (where ns.node_type = 'skill' and not ns.is_observed),
      'mastered_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed and ns.mastery_band = 'mastered'),
      'mastery_candidate_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed and ns.mastery_band = 'mastery_candidate'),
      'secure_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed and ns.mastery_band = 'secure'),
      'developing_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed and ns.mastery_band = 'developing'),
      'emerging_skills', count(*) filter (where ns.node_type = 'skill' and ns.is_observed and ns.mastery_band = 'emerging'),
      'needs_refresh_count', count(*) filter (where ns.node_type in ('topic', 'skill') and ns.is_observed and ns.freshness = 'needs_refresh'),
      'active_recovery_count', count(*) filter (where ns.node_type in ('topic', 'skill') and ns.is_observed and ns.recovery_signal = 'review_suggested')
    ) as obj
    from node_states ns
  ),
  topic_json as (
    select
      t.subject_node_id,
      t.catalog_sort_path,
      t.learning_node_id,
      jsonb_build_object(
        'learning_node_id', t.learning_node_id,
        'domain_node_id', t.parent_domain_id,
        'domain_title', t.parent_domain_title,
        'canonical_key', t.canonical_key,
        'title', t.title,
        'grade_min', t.grade_min,
        'grade_max', t.grade_max,
        'sort_order', t.sort_order,
        'catalog_sort_path', to_jsonb(t.catalog_sort_path),
        'is_observed', t.is_observed,
        'mastery_score', t.mastery_score,
        'mastery_band', t.mastery_band,
        'confidence_band', t.confidence_band,
        'confidence_units', t.confidence_units,
        'freshness', t.freshness,
        'recovery_signal', t.recovery_signal,
        'latest_effective_occurred_at', t.latest_effective_occurred_at,
        'mastery_attained_at', t.mastery_attained_at,
        'skill_coverage', jsonb_build_object(
          'total_skills', count(s.learning_node_id),
          'observed_skills', count(s.learning_node_id) filter (where s.is_observed),
          'unseen_skills', count(s.learning_node_id) filter (where not s.is_observed),
          'mastered_skills', count(s.learning_node_id) filter (where s.is_observed and s.mastery_band = 'mastered'),
          'needs_refresh_skills', count(s.learning_node_id) filter (where s.is_observed and s.freshness = 'needs_refresh'),
          'active_recovery_skills', count(s.learning_node_id) filter (where s.is_observed and s.recovery_signal = 'review_suggested')
        ),
        'skills', coalesce(
          jsonb_agg(
            jsonb_build_object(
              'learning_node_id', s.learning_node_id,
              'canonical_key', s.canonical_key,
              'title', s.title,
              'grade_min', s.grade_min,
              'grade_max', s.grade_max,
              'sort_order', s.sort_order,
              'catalog_sort_path', to_jsonb(s.catalog_sort_path),
              'is_observed', s.is_observed,
              'mastery_score', s.mastery_score,
              'mastery_band', s.mastery_band,
              'confidence_band', s.confidence_band,
              'confidence_units', s.confidence_units,
              'freshness', s.freshness,
              'recovery_signal', s.recovery_signal,
              'latest_effective_occurred_at', s.latest_effective_occurred_at,
              'mastery_attained_at', s.mastery_attained_at,
              'prerequisite_count', s.prerequisite_count,
              'attained_prerequisite_count', s.attained_prerequisite_count,
              'is_prerequisite_satisfied', s.is_prerequisite_satisfied,
              'is_grade_compatible', s.is_grade_compatible
            )
            order by s.catalog_sort_path asc, s.learning_node_id asc
          ) filter (where s.learning_node_id is not null),
          '[]'::jsonb
        )
      ) as obj
    from node_states t
    left join node_states s
      on s.node_type = 'skill'
     and s.parent_topic_id = t.learning_node_id
    where t.node_type = 'topic'
    group by
      t.subject_node_id,
      t.learning_node_id,
      t.parent_domain_id,
      t.parent_domain_title,
      t.canonical_key,
      t.title,
      t.grade_min,
      t.grade_max,
      t.sort_order,
      t.catalog_sort_path,
      t.is_observed,
      t.mastery_score,
      t.mastery_band,
      t.confidence_band,
      t.confidence_units,
      t.freshness,
      t.recovery_signal,
      t.latest_effective_occurred_at,
      t.mastery_attained_at
  ),
  subject_json as (
    select
      sub.sort_order,
      sub.learning_node_id,
      jsonb_build_object(
        'subject_node_id', sub.learning_node_id,
        'subject_key', sub.subject_key,
        'canonical_key', sub.canonical_key,
        'title', sub.title,
        'sort_order', sub.sort_order,
        'subject_state', jsonb_build_object(
          'is_observed', sub.is_observed,
          'mastery_score', sub.mastery_score,
          'mastery_band', sub.mastery_band,
          'confidence_band', sub.confidence_band,
          'confidence_units', sub.confidence_units,
          'freshness', sub.freshness,
          'effective_evidence_count', coalesce(sub.effective_evidence_count, 0),
          'distinct_assessment_count', coalesce(sub.distinct_assessment_count, 0),
          'latest_effective_occurred_at', sub.latest_effective_occurred_at,
          'mastery_attained_at', sub.mastery_attained_at
        ),
        'coverage', (
          select jsonb_build_object(
            'total_domains', count(*) filter (where desc_n.node_type = 'domain'),
            'observed_domains', count(*) filter (where desc_n.node_type = 'domain' and desc_n.is_observed),
            'unseen_domains', count(*) filter (where desc_n.node_type = 'domain' and not desc_n.is_observed),
            'total_topics', count(*) filter (where desc_n.node_type = 'topic'),
            'observed_topics', count(*) filter (where desc_n.node_type = 'topic' and desc_n.is_observed),
            'unseen_topics', count(*) filter (where desc_n.node_type = 'topic' and not desc_n.is_observed),
            'total_skills', count(*) filter (where desc_n.node_type = 'skill'),
            'observed_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed),
            'unseen_skills', count(*) filter (where desc_n.node_type = 'skill' and not desc_n.is_observed),
            'mastered_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed and desc_n.mastery_band = 'mastered'),
            'mastery_candidate_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed and desc_n.mastery_band = 'mastery_candidate'),
            'secure_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed and desc_n.mastery_band = 'secure'),
            'developing_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed and desc_n.mastery_band = 'developing'),
            'emerging_skills', count(*) filter (where desc_n.node_type = 'skill' and desc_n.is_observed and desc_n.mastery_band = 'emerging'),
            'needs_refresh_count', count(*) filter (where desc_n.node_type in ('topic', 'skill') and desc_n.is_observed and desc_n.freshness = 'needs_refresh'),
            'active_recovery_count', count(*) filter (where desc_n.node_type in ('topic', 'skill') and desc_n.is_observed and desc_n.recovery_signal = 'review_suggested')
          )
          from node_states desc_n
          where desc_n.subject_node_id = sub.learning_node_id
        ),
        'topics', coalesce(
          (
            select jsonb_agg(tj.obj order by tj.catalog_sort_path asc, tj.learning_node_id asc)
            from topic_json tj
            where tj.subject_node_id = sub.learning_node_id
          ),
          '[]'::jsonb
        )
      ) as obj
    from node_states sub
    where sub.node_type = 'subject'
  )
  select
    (select obj from overall_cov),
    coalesce((select jsonb_agg(sj.obj order by sj.sort_order asc, sj.learning_node_id asc) from subject_json sj), '[]'::jsonb)
  into v_overall_coverage, v_subjects;

  return jsonb_build_object(
    'child_id', p_child_id,
    'school_grade', v_child.school_grade,
    'active_catalog_version', v_active_version,
    'as_of', v_as_of,
    'overall_coverage', v_overall_coverage,
    'subjects', v_subjects
  );
end;
$$;

revoke all on function private.get_child_learning_overview_at(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. INTERNAL HELPER: private.get_node_learning_state_at
-- ---------------------------------------------------------------------------

create or replace function private.get_node_learning_state_at(
  p_child_id uuid,
  p_learning_node_id uuid,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_as_of timestamptz;
  v_child record;
  v_active_version text;
  v_result jsonb;
begin
  v_as_of := coalesce(p_as_of, transaction_timestamp());

  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  with active_subjects as (
    select
      r.id as learning_node_id,
      r.id as subject_node_id,
      r.catalog_version,
      r.node_type,
      r.subject_key,
      r.canonical_key,
      r.title,
      r.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      r.grade_min,
      r.grade_max,
      r.sort_order,
      array[r.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes r
    where r.catalog_version = v_active_version
      and r.node_type = 'subject'
      and r.is_active = true
  ),
  active_domains as (
    select
      d.id as learning_node_id,
      r.subject_node_id,
      d.catalog_version,
      d.node_type,
      d.subject_key,
      d.canonical_key,
      d.title,
      d.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      d.grade_min,
      d.grade_max,
      d.sort_order,
      array[r.sort_order, d.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes d
    join active_subjects r on r.learning_node_id = d.parent_id
    where d.catalog_version = v_active_version
      and d.node_type = 'domain'
      and d.is_active = true
  ),
  active_topics as (
    select
      t.id as learning_node_id,
      d.subject_node_id,
      t.catalog_version,
      t.node_type,
      t.subject_key,
      t.canonical_key,
      t.title,
      t.parent_id,
      d.learning_node_id as parent_domain_id,
      d.title as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      t.grade_min,
      t.grade_max,
      t.sort_order,
      (d.catalog_sort_path || t.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes t
    join active_domains d on d.learning_node_id = t.parent_id
    where t.catalog_version = v_active_version
      and t.node_type = 'topic'
      and t.is_active = true
  ),
  active_skills as (
    select
      s.id as learning_node_id,
      t.subject_node_id,
      s.catalog_version,
      s.node_type,
      s.subject_key,
      s.canonical_key,
      s.title,
      s.parent_id,
      t.parent_domain_id,
      t.parent_domain_title,
      t.learning_node_id as parent_topic_id,
      t.title as parent_topic_title,
      s.grade_min,
      s.grade_max,
      s.sort_order,
      (t.catalog_sort_path || s.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes s
    join active_topics t on t.learning_node_id = s.parent_id
    where s.catalog_version = v_active_version
      and s.node_type = 'skill'
      and s.is_active = true
  ),
  universe as (
    select * from active_subjects
    union all
    select * from active_domains
    union all
    select * from active_topics
    union all
    select * from active_skills
  ),
  target as (
    select
      u.*,
      (cms.learning_node_id is not null) as is_observed,
      cms.mastery_score,
      coalesce(cms.effective_evidence_count, 0) as effective_evidence_count,
      coalesce(cms.distinct_assessment_count, 0) as distinct_assessment_count,
      cms.mastery_attained_at,
      case
        when cms.learning_node_id is null then null
        when cms.mastery_attained_at is not null and cms.mastery_attained_at <= v_as_of then 'mastered'
        when cms.mastery_score >= 85 then 'mastery_candidate'
        when cms.mastery_score >= 70 then 'secure'
        when cms.mastery_score >= 50 then 'developing'
        else 'emerging'
      end as mastery_band,
      case
        when cms.learning_node_id is null then null
        else conf.band
      end as confidence_band,
      case
        when cms.learning_node_id is null then 0.00::numeric(5,2)
        else conf.units
      end as confidence_units,
      case
        when cms.learning_node_id is null then 0
        else conf.distinct_recent_vles
      end as distinct_recent_vle_count,
      vis.latest_effective_occurred_at,
      case
        when cms.learning_node_id is null or vis.latest_effective_occurred_at is null then 'unknown'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '14 days' then 'recent'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '45 days' then 'aging'
        else 'needs_refresh'
      end as freshness,
      case
        when cms.learning_node_id is null or vis.latest_effective_occurred_at is null then null::integer
        else floor(extract(epoch from greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at)) / 86400)::integer
      end as days_since_last_evidence,
      case
        when cms.learning_node_id is null then 'none'
        else rec.recovery_signal
      end as recovery_signal,
      case
        when cms.learning_node_id is null then null
        else rec.latest_unresolved_weakness_at
      end as latest_unresolved_weakness_at,
      case
        when u.grade_min is null and u.grade_max is null then true
        when v_child.school_grade is null then false
        else (u.grade_min is null or v_child.school_grade >= u.grade_min)
         and (u.grade_max is null or v_child.school_grade <= u.grade_max)
      end as is_grade_compatible,
      coalesce(prereq.prerequisite_count, 0) as prerequisite_count,
      coalesce(prereq.attained_prerequisite_count, 0) as attained_prerequisite_count,
      coalesce(prereq.is_prerequisite_satisfied, true) as is_prerequisite_satisfied,
      coalesce(prereq.prerequisites_json, '[]'::jsonb) as prerequisites_json
    from universe u
    left join public.child_mastery_states cms
      on cms.child_id = p_child_id
     and cms.learning_node_id = u.learning_node_id
    cross join lateral (
      select
        coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00)::numeric(5,2) as units,
        count(distinct ev.verified_learning_event_id)::integer as distinct_recent_vles,
        case
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) > 3.50
               and count(distinct ev.verified_learning_event_id) >= 2 then 'high'
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) >= 1.50 then 'medium'
          else 'low'
        end as band
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at >= v_as_of - interval '60 days'
        and ev.effective_occurred_at <= v_as_of
    ) conf
    cross join lateral (
      select max(ev.effective_occurred_at) as latest_effective_occurred_at
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at <= v_as_of
        and ev.verified_at <= v_as_of
    ) vis
    cross join lateral private.evaluate_node_recovery_at(
      p_child_id,
      u.learning_node_id,
      case when cms.learning_node_id is not null then u.node_type else null end,
      v_as_of
    ) rec
    left join lateral (
      select
        count(*)::integer as prerequisite_count,
        count(*) filter (
          where p_u.learning_node_id is not null
            and cms_p.mastery_attained_at is not null
            and cms_p.mastery_attained_at <= v_as_of
        )::integer as attained_prerequisite_count,
        (
          count(*) = count(*) filter (
            where p_u.learning_node_id is not null
              and cms_p.mastery_attained_at is not null
              and cms_p.mastery_attained_at <= v_as_of
          )
        ) as is_prerequisite_satisfied,
        coalesce(
          jsonb_agg(
            jsonb_build_object(
              'learning_node_id', n_p.id,
              'canonical_key', n_p.canonical_key,
              'title', n_p.title,
              'is_observed', (cms_p.learning_node_id is not null),
              'mastery_score', cms_p.mastery_score,
              'mastery_band', case
                when cms_p.learning_node_id is null then null
                when cms_p.mastery_attained_at is not null and cms_p.mastery_attained_at <= v_as_of then 'mastered'
                when cms_p.mastery_score >= 85 then 'mastery_candidate'
                when cms_p.mastery_score >= 70 then 'secure'
                when cms_p.mastery_score >= 50 then 'developing'
                else 'emerging'
              end,
              'mastery_attained_at', cms_p.mastery_attained_at,
              'is_attained', (
                p_u.learning_node_id is not null
                and cms_p.mastery_attained_at is not null
                and cms_p.mastery_attained_at <= v_as_of
              )
            )
            order by coalesce(p_u.catalog_sort_path, array[n_p.sort_order]::integer[]) asc, n_p.id asc
          ),
          '[]'::jsonb
        ) as prerequisites_json
      from public.learning_prerequisites lp
      join public.learning_nodes n_p on n_p.id = lp.prerequisite_node_id
      left join active_skills p_u on p_u.learning_node_id = lp.prerequisite_node_id
      left join public.child_mastery_states cms_p
        on cms_p.child_id = p_child_id
       and cms_p.learning_node_id = lp.prerequisite_node_id
      where u.node_type = 'skill'
        and lp.catalog_version = v_active_version
        and lp.dependent_node_id = u.learning_node_id
    ) prereq on true
    where u.learning_node_id = p_learning_node_id
  ),
  dependents_cte as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'learning_node_id', dep_s.learning_node_id,
          'canonical_key', dep_s.canonical_key,
          'title', dep_s.title,
          'grade_min', dep_s.grade_min,
          'grade_max', dep_s.grade_max,
          'is_observed', (cms_d.learning_node_id is not null),
          'is_grade_compatible', case
            when dep_s.grade_min is null and dep_s.grade_max is null then true
            when v_child.school_grade is null then false
            else (dep_s.grade_min is null or v_child.school_grade >= dep_s.grade_min)
             and (dep_s.grade_max is null or v_child.school_grade <= dep_s.grade_max)
          end,
          'prerequisite_count', coalesce(dep_pr.prerequisite_count, 0),
          'attained_prerequisite_count', coalesce(dep_pr.attained_prerequisite_count, 0),
          'is_prerequisite_satisfied', coalesce(dep_pr.is_prerequisite_satisfied, true)
        )
        order by dep_s.catalog_sort_path asc, dep_s.learning_node_id asc
      ),
      '[]'::jsonb
    ) as dependents_json
    from target t
    join public.learning_prerequisites lp_out
      on t.node_type = 'skill'
     and lp_out.catalog_version = v_active_version
     and lp_out.prerequisite_node_id = t.learning_node_id
    join active_skills dep_s
      on dep_s.learning_node_id = lp_out.dependent_node_id
    left join public.child_mastery_states cms_d
      on cms_d.child_id = p_child_id
     and cms_d.learning_node_id = dep_s.learning_node_id
    left join lateral (
      select
        count(*)::integer as prerequisite_count,
        count(*) filter (
          where p_u2.learning_node_id is not null
            and cms_p2.mastery_attained_at is not null
            and cms_p2.mastery_attained_at <= v_as_of
        )::integer as attained_prerequisite_count,
        (
          count(*) = count(*) filter (
            where p_u2.learning_node_id is not null
              and cms_p2.mastery_attained_at is not null
              and cms_p2.mastery_attained_at <= v_as_of
          )
        ) as is_prerequisite_satisfied
      from public.learning_prerequisites lp2
      left join active_skills p_u2 on p_u2.learning_node_id = lp2.prerequisite_node_id
      left join public.child_mastery_states cms_p2
        on cms_p2.child_id = p_child_id
       and cms_p2.learning_node_id = lp2.prerequisite_node_id
      where lp2.catalog_version = v_active_version
        and lp2.dependent_node_id = dep_s.learning_node_id
    ) dep_pr on true
  ),
  latest_ev_cte as (
    select jsonb_build_object(
      'evidence_event_id', ev.id,
      'verified_learning_event_id', ev.verified_learning_event_id,
      'assessment_id', ev.assessment_id,
      'score_source', ev.score_source,
      'performance_pct', ev.performance_pct,
      'difficulty', ev.difficulty,
      'item_count', ev.item_count,
      'correct_count', ev.correct_count,
      'effective_occurred_at', ev.effective_occurred_at,
      'verified_at', ev.verified_at
    ) as latest_ev_json
    from target t
    join public.learning_evidence_events ev
      on t.is_observed
     and ev.child_id = p_child_id
     and ev.learning_node_id = t.learning_node_id
     and ev.effective_occurred_at <= v_as_of
     and ev.verified_at <= v_as_of
    order by
      ev.effective_occurred_at desc,
      ev.verified_at desc,
      ev.verified_learning_event_id desc
    limit 1
  ),
  desc_coverage_cte as (
    select jsonb_build_object(
      'total_descendant_topics', count(*) filter (where desc_u.node_type = 'topic'),
      'observed_descendant_topics', count(*) filter (where desc_u.node_type = 'topic' and cms_desc.learning_node_id is not null),
      'unseen_descendant_topics', count(*) filter (where desc_u.node_type = 'topic' and cms_desc.learning_node_id is null),
      'total_descendant_skills', count(*) filter (where desc_u.node_type = 'skill'),
      'observed_descendant_skills', count(*) filter (where desc_u.node_type = 'skill' and cms_desc.learning_node_id is not null),
      'unseen_descendant_skills', count(*) filter (where desc_u.node_type = 'skill' and cms_desc.learning_node_id is null)
    ) as coverage_json
    from target t
    left join universe desc_u
      on desc_u.learning_node_id <> t.learning_node_id
     and (
       (t.node_type = 'subject' and desc_u.subject_node_id = t.learning_node_id)
       or (t.node_type = 'domain' and desc_u.parent_domain_id = t.learning_node_id)
       or (t.node_type = 'topic' and desc_u.parent_topic_id = t.learning_node_id)
     )
    left join public.child_mastery_states cms_desc
      on cms_desc.child_id = p_child_id
     and cms_desc.learning_node_id = desc_u.learning_node_id
  )
  select jsonb_build_object(
    'child_id', p_child_id,
    'school_grade', v_child.school_grade,
    'active_catalog_version', v_active_version,
    'as_of', v_as_of,
    'node', jsonb_build_object(
      'learning_node_id', t.learning_node_id,
      'catalog_version', t.catalog_version,
      'node_type', t.node_type,
      'subject_key', t.subject_key,
      'canonical_key', t.canonical_key,
      'title', t.title,
      'parent_id', t.parent_id,
      'parent_topic_id', t.parent_topic_id,
      'parent_topic_title', t.parent_topic_title,
      'parent_domain_id', t.parent_domain_id,
      'parent_domain_title', t.parent_domain_title,
      'subject_node_id', t.subject_node_id,
      'grade_min', t.grade_min,
      'grade_max', t.grade_max,
      'sort_order', t.sort_order,
      'catalog_sort_path', to_jsonb(t.catalog_sort_path)
    ),
    'state', jsonb_build_object(
      'is_observed', t.is_observed,
      'mastery_score', t.mastery_score,
      'mastery_band', t.mastery_band,
      'mastery_attained_at', t.mastery_attained_at,
      'confidence_band', t.confidence_band,
      'confidence_units', t.confidence_units,
      'distinct_recent_vle_count', t.distinct_recent_vle_count,
      'effective_evidence_count', t.effective_evidence_count,
      'distinct_assessment_count', t.distinct_assessment_count,
      'freshness', t.freshness,
      'days_since_last_evidence', t.days_since_last_evidence,
      'recovery_signal', t.recovery_signal,
      'latest_unresolved_weakness_at', t.latest_unresolved_weakness_at,
      'recommended_difficulty', case
        when t.node_type in ('subject', 'domain') then null
        when t.node_type = 'topic' and not t.is_observed then null
        when t.node_type = 'skill' and not t.is_observed then
          case
            when t.is_grade_compatible and t.is_prerequisite_satisfied then 'normal'
            else null
          end
        when t.recovery_signal = 'review_suggested' then 'below_level'
        when t.freshness = 'needs_refresh' and t.mastery_score >= 70.00 then 'normal'
        when t.freshness <> 'needs_refresh' and t.mastery_score >= 50.00 and t.mastery_score < 70.00 and t.mastery_band <> 'mastered' then 'normal'
        when t.freshness <> 'needs_refresh' and t.mastery_score >= 70.00 and t.mastery_score < 85.00 and t.mastery_band <> 'mastered' then 'hard'
        when (t.mastery_score >= 85.00 or t.mastery_band = 'mastered') then
          case
            when t.mastery_score >= 90.00 and t.confidence_band = 'high' then 'challenge'
            else 'hard'
          end
        else 'normal'
      end,
      'is_grade_compatible', t.is_grade_compatible
    ),
    'latest_evidence', (select latest_ev_json from latest_ev_cte),
    'coverage', (select coverage_json from desc_coverage_cte),
    'prerequisite_state', case
      when t.node_type = 'skill' then jsonb_build_object(
        'applicable', true,
        'prerequisite_count', t.prerequisite_count,
        'attained_prerequisite_count', t.attained_prerequisite_count,
        'is_satisfied', t.is_prerequisite_satisfied,
        'prerequisites', t.prerequisites_json,
        'dependents', coalesce((select dependents_json from dependents_cte), '[]'::jsonb)
      )
      else jsonb_build_object(
        'applicable', false,
        'prerequisite_count', 0,
        'attained_prerequisite_count', 0,
        'is_satisfied', true,
        'prerequisites', '[]'::jsonb,
        'dependents', '[]'::jsonb
      )
    end
  )
  into v_result
  from target t;

  if v_result is null then
    raise exception 'Learning node not found in active catalog' using errcode = 'P0002';
  end if;

  return v_result;
end;
$$;

revoke all on function private.get_node_learning_state_at(uuid, uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. INTERNAL HELPER: private.get_next_challenge_candidates_at
-- ---------------------------------------------------------------------------

create or replace function private.get_next_challenge_candidates_at(
  p_child_id uuid,
  p_subject_key text,
  p_limit integer,
  p_as_of timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_as_of timestamptz;
  v_limit integer;
  v_child record;
  v_active_version text;
  v_candidates jsonb;
begin
  v_as_of := coalesce(p_as_of, transaction_timestamp());
  v_limit := coalesce(p_limit, 3);

  if v_limit < 1 or v_limit > 3 then
    raise exception 'Candidate limit must be between 1 and 3' using errcode = '22000';
  end if;

  if p_subject_key is not null
     and p_subject_key not in ('math', 'english', 'literature', 'science', 'other') then
    raise exception 'Invalid subject_key' using errcode = '22000';
  end if;

  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  with active_subjects as (
    select
      r.id as learning_node_id,
      r.id as subject_node_id,
      r.catalog_version,
      r.node_type,
      r.subject_key,
      r.canonical_key,
      r.title,
      r.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      r.grade_min,
      r.grade_max,
      r.sort_order,
      array[r.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes r
    where r.catalog_version = v_active_version
      and r.node_type = 'subject'
      and r.is_active = true
  ),
  active_domains as (
    select
      d.id as learning_node_id,
      r.subject_node_id,
      d.catalog_version,
      d.node_type,
      d.subject_key,
      d.canonical_key,
      d.title,
      d.parent_id,
      null::uuid as parent_domain_id,
      null::text as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      d.grade_min,
      d.grade_max,
      d.sort_order,
      array[r.sort_order, d.sort_order]::integer[] as catalog_sort_path
    from public.learning_nodes d
    join active_subjects r on r.learning_node_id = d.parent_id
    where d.catalog_version = v_active_version
      and d.node_type = 'domain'
      and d.is_active = true
  ),
  active_topics as (
    select
      t.id as learning_node_id,
      d.subject_node_id,
      t.catalog_version,
      t.node_type,
      t.subject_key,
      t.canonical_key,
      t.title,
      t.parent_id,
      d.learning_node_id as parent_domain_id,
      d.title as parent_domain_title,
      null::uuid as parent_topic_id,
      null::text as parent_topic_title,
      t.grade_min,
      t.grade_max,
      t.sort_order,
      (d.catalog_sort_path || t.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes t
    join active_domains d on d.learning_node_id = t.parent_id
    where t.catalog_version = v_active_version
      and t.node_type = 'topic'
      and t.is_active = true
  ),
  active_skills as (
    select
      s.id as learning_node_id,
      t.subject_node_id,
      s.catalog_version,
      s.node_type,
      s.subject_key,
      s.canonical_key,
      s.title,
      s.parent_id,
      t.parent_domain_id,
      t.parent_domain_title,
      t.learning_node_id as parent_topic_id,
      t.title as parent_topic_title,
      s.grade_min,
      s.grade_max,
      s.sort_order,
      (t.catalog_sort_path || s.sort_order)::integer[] as catalog_sort_path
    from public.learning_nodes s
    join active_topics t on t.learning_node_id = s.parent_id
    where s.catalog_version = v_active_version
      and s.node_type = 'skill'
      and s.is_active = true
  ),
  universe as (
    select * from active_subjects
    union all
    select * from active_domains
    union all
    select * from active_topics
    union all
    select * from active_skills
  ),
  node_states as (
    select
      u.*,
      (cms.learning_node_id is not null) as is_observed,
      cms.mastery_score,
      cms.mastery_attained_at,
      case
        when cms.learning_node_id is null then null
        when cms.mastery_attained_at is not null and cms.mastery_attained_at <= v_as_of then 'mastered'
        when cms.mastery_score >= 85 then 'mastery_candidate'
        when cms.mastery_score >= 70 then 'secure'
        when cms.mastery_score >= 50 then 'developing'
        else 'emerging'
      end as mastery_band,
      case
        when cms.learning_node_id is null then null
        else conf.band
      end as confidence_band,
      vis.latest_effective_occurred_at,
      case
        when cms.learning_node_id is null or vis.latest_effective_occurred_at is null then 'unknown'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '14 days' then 'recent'
        when greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at) <= interval '45 days' then 'aging'
        else 'needs_refresh'
      end as freshness,
      case
        when cms.learning_node_id is null or vis.latest_effective_occurred_at is null then null::integer
        else floor(extract(epoch from greatest(interval '0 seconds', v_as_of - vis.latest_effective_occurred_at)) / 86400)::integer
      end as days_since_last_evidence,
      case
        when cms.learning_node_id is null then 'none'
        else rec.recovery_signal
      end as recovery_signal,
      case
        when cms.learning_node_id is null then null
        else rec.latest_unresolved_weakness_at
      end as latest_unresolved_weakness_at,
      case
        when u.grade_min is null and u.grade_max is null then true
        when v_child.school_grade is null then false
        else (u.grade_min is null or v_child.school_grade >= u.grade_min)
         and (u.grade_max is null or v_child.school_grade <= u.grade_max)
      end as is_grade_compatible,
      coalesce(prereq.prerequisite_count, 0) as prerequisite_count,
      coalesce(prereq.attained_prerequisite_count, 0) as attained_prerequisite_count,
      coalesce(prereq.is_prerequisite_satisfied, true) as is_prerequisite_satisfied,
      coalesce(prereq.attained_prerequisite_titles, '[]'::jsonb) as attained_prerequisite_titles
    from universe u
    left join public.child_mastery_states cms
      on cms.child_id = p_child_id
     and cms.learning_node_id = u.learning_node_id
    cross join lateral (
      select
        case
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) > 3.50
               and count(distinct ev.verified_learning_event_id) >= 2 then 'high'
          when coalesce(round(sum(ev.specificity_weight * ev.level_weight), 2), 0.00) >= 1.50 then 'medium'
          else 'low'
        end as band
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at >= v_as_of - interval '60 days'
        and ev.effective_occurred_at <= v_as_of
    ) conf
    cross join lateral (
      select max(ev.effective_occurred_at) as latest_effective_occurred_at
      from public.learning_evidence_events ev
      where cms.learning_node_id is not null
        and ev.child_id = p_child_id
        and ev.learning_node_id = u.learning_node_id
        and ev.effective_occurred_at <= v_as_of
        and ev.verified_at <= v_as_of
    ) vis
    cross join lateral private.evaluate_node_recovery_at(
      p_child_id,
      u.learning_node_id,
      case when cms.learning_node_id is not null then u.node_type else null end,
      v_as_of
    ) rec
    left join lateral (
      select
        count(*)::integer as prerequisite_count,
        count(*) filter (
          where p_u.learning_node_id is not null
            and cms_p.mastery_attained_at is not null
            and cms_p.mastery_attained_at <= v_as_of
        )::integer as attained_prerequisite_count,
        (
          count(*) = count(*) filter (
            where p_u.learning_node_id is not null
              and cms_p.mastery_attained_at is not null
              and cms_p.mastery_attained_at <= v_as_of
          )
        ) as is_prerequisite_satisfied,
        coalesce(
          jsonb_agg(p_u.title order by p_u.catalog_sort_path asc, p_u.learning_node_id asc) filter (
            where p_u.learning_node_id is not null
              and cms_p.mastery_attained_at is not null
              and cms_p.mastery_attained_at <= v_as_of
          ),
          '[]'::jsonb
        ) as attained_prerequisite_titles
      from public.learning_prerequisites lp
      left join active_skills p_u on p_u.learning_node_id = lp.prerequisite_node_id
      left join public.child_mastery_states cms_p
        on cms_p.child_id = p_child_id
       and cms_p.learning_node_id = lp.prerequisite_node_id
      where u.node_type = 'skill'
        and lp.catalog_version = v_active_version
        and lp.dependent_node_id = u.learning_node_id
    ) prereq on true
  ),
  classified as (
    select
      ns.*,
      case
        when ns.node_type in ('topic', 'skill')
             and ns.is_observed
             and ns.recovery_signal = 'review_suggested' then 1
        when ns.node_type in ('topic', 'skill')
             and ns.is_observed
             and ns.recovery_signal = 'none'
             and ns.freshness = 'needs_refresh'
             and ns.mastery_score >= 70.00 then 2
        when ns.node_type in ('topic', 'skill')
             and ns.is_observed
             and ns.recovery_signal = 'none'
             and ns.freshness <> 'needs_refresh'
             and ns.mastery_score >= 50.00
             and ns.mastery_score < 85.00
             and ns.mastery_band <> 'mastered' then 3
        when ns.node_type = 'skill'
             and not ns.is_observed
             and ns.prerequisite_count >= 1
             and ns.is_prerequisite_satisfied
             and ns.is_grade_compatible then 4
        when ns.node_type = 'skill'
             and not ns.is_observed
             and ns.prerequisite_count = 0
             and ns.is_grade_compatible then 5
        else null
      end as priority_rank,
      case
        when ns.node_type = 'skill'
             and not ns.is_observed
             and ns.prerequisite_count = 0
             and ns.is_grade_compatible then
          case
            when exists (
              select 1 from node_states s2
              where s2.node_type = 'skill'
                and s2.parent_topic_id = ns.parent_topic_id
                and s2.is_observed
            ) then 0
            when exists (
              select 1 from node_states d2
              where (d2.learning_node_id = ns.parent_domain_id or d2.parent_domain_id = ns.parent_domain_id)
                and d2.is_observed
            ) then 1
            when exists (
              select 1 from node_states sub2
              where sub2.subject_key = ns.subject_key
                and sub2.is_observed
            ) then 2
            else 3
          end
        else null::integer
      end as explore_proximity_rank
    from node_states ns
    where p_subject_key is null or ns.subject_key = p_subject_key
  ),
  eligible as (
    select
      c.*,
      case c.priority_rank
        when 1 then 'recovery'
        when 2 then 'refresh'
        when 3 then 'developing'
        when 4 then 'unlock'
        when 5 then 'explore'
      end as priority_class,
      case c.priority_rank
        when 1 then 'recovery_recent_errors'
        when 2 then 'refresh_stale_secure_skill'
        when 3 then 'developing_keep_practicing'
        when 4 then 'unlock_prerequisites_mastered'
        when 5 then 'explore_available_skill'
      end as reason_code,
      case
        when c.priority_rank = 1 then 'below_level'
        when c.priority_rank = 2 then 'normal'
        when c.priority_rank = 3 and c.mastery_score < 70.00 then 'normal'
        when c.priority_rank = 3 and c.mastery_score >= 70.00 then 'hard'
        when c.priority_rank = 4 then 'normal'
        when c.priority_rank = 5 then 'normal'
      end as recommended_difficulty
    from classified c
    where c.priority_rank is not null
  ),
  ranked as (
    select
      row_number() over (
        order by
          e.priority_rank asc,
          case when e.priority_rank = 1 then e.latest_unresolved_weakness_at end desc nulls last,
          case when e.priority_rank = 2 then e.latest_effective_occurred_at end asc nulls last,
          case when e.priority_rank = 3 then round(e.mastery_score * 100)::integer end asc nulls last,
          case when e.priority_rank = 5 then e.explore_proximity_rank end asc nulls last,
          e.catalog_sort_path asc,
          e.learning_node_id asc
      )::integer as rank,
      e.*
    from eligible e
    order by
      e.priority_rank asc,
      case when e.priority_rank = 1 then e.latest_unresolved_weakness_at end desc nulls last,
      case when e.priority_rank = 2 then e.latest_effective_occurred_at end asc nulls last,
      case when e.priority_rank = 3 then round(e.mastery_score * 100)::integer end asc nulls last,
      case when e.priority_rank = 5 then e.explore_proximity_rank end asc nulls last,
      e.catalog_sort_path asc,
      e.learning_node_id asc
    limit v_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'rank', r.rank,
        'learning_node_id', r.learning_node_id,
        'catalog_version', r.catalog_version,
        'canonical_key', r.canonical_key,
        'title', r.title,
        'node_type', r.node_type,
        'subject_key', r.subject_key,
        'parent_topic_id', r.parent_topic_id,
        'parent_topic_title', r.parent_topic_title,
        'parent_domain_id', r.parent_domain_id,
        'parent_domain_title', r.parent_domain_title,
        'grade_min', r.grade_min,
        'grade_max', r.grade_max,
        'sort_order', r.sort_order,
        'catalog_sort_path', to_jsonb(r.catalog_sort_path),
        'priority_class', r.priority_class,
        'reason_code', r.reason_code,
        'recommended_difficulty', r.recommended_difficulty,
        'is_observed', r.is_observed,
        'mastery_score', r.mastery_score,
        'mastery_band', r.mastery_band,
        'confidence_band', r.confidence_band,
        'freshness', r.freshness,
        'recovery_signal', r.recovery_signal,
        'explanation', jsonb_build_object(
          'latest_effective_occurred_at', r.latest_effective_occurred_at,
          'days_since_last_evidence', r.days_since_last_evidence,
          'latest_unresolved_weakness_at', r.latest_unresolved_weakness_at,
          'prerequisite_count', r.prerequisite_count,
          'attained_prerequisite_titles', case
            when r.priority_rank = 4 then r.attained_prerequisite_titles
            else '[]'::jsonb
          end,
          'explore_proximity_rank', r.explore_proximity_rank
        ),
        'as_of', v_as_of
      )
      order by r.rank asc
    ),
    '[]'::jsonb
  )
  into v_candidates
  from ranked r;

  return jsonb_build_object(
    'child_id', p_child_id,
    'school_grade', v_child.school_grade,
    'active_catalog_version', v_active_version,
    'subject_key_filter', p_subject_key,
    'limit', v_limit,
    'as_of', v_as_of,
    'candidates', v_candidates
  );
end;
$$;

revoke all on function private.get_next_challenge_candidates_at(uuid, text, integer, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. PUBLIC READ RPCs (STABLE, SECURITY DEFINER, SET search_path = '')
-- ---------------------------------------------------------------------------

-- 5.1 public.get_child_learning_overview
create or replace function public.get_child_learning_overview(
  p_child_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child record;
  v_active_version text;
  v_as_of timestamptz;
begin
  -- 1. Parameter validation
  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  -- 2. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 3. Server-derived tenancy & active child check
  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  -- 4. Family adult or exact paired-child authorization
  if not (
    private.is_active_family_adult(v_child.family_id)
    or private.is_active_child_device(v_child.family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 5. Active catalog check
  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  -- 6. Single clock capture & delegation
  v_as_of := transaction_timestamp();
  return private.get_child_learning_overview_at(p_child_id, v_as_of);
end;
$$;

revoke all on function public.get_child_learning_overview(uuid) from public, anon;
grant execute on function public.get_child_learning_overview(uuid) to authenticated, service_role;

-- 5.2 public.get_node_learning_state
create or replace function public.get_node_learning_state(
  p_child_id uuid,
  p_learning_node_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child record;
  v_active_version text;
  v_as_of timestamptz;
begin
  -- 1. Parameter validation
  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  if p_learning_node_id is null then
    raise exception 'Learning node ID is required' using errcode = '22000';
  end if;

  -- 2. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 3. Server-derived tenancy & active child check
  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  -- 4. Family adult or exact paired-child authorization
  if not (
    private.is_active_family_adult(v_child.family_id)
    or private.is_active_child_device(v_child.family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 5. Active catalog check
  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  -- 6. Single clock capture & delegation (active node check enforced inside helper -> P0002)
  v_as_of := transaction_timestamp();
  return private.get_node_learning_state_at(p_child_id, p_learning_node_id, v_as_of);
end;
$$;

revoke all on function public.get_node_learning_state(uuid, uuid) from public, anon;
grant execute on function public.get_node_learning_state(uuid, uuid) to authenticated, service_role;

-- 5.3 public.get_next_challenge_candidates
create or replace function public.get_next_challenge_candidates(
  p_child_id uuid,
  p_subject_key text default null,
  p_limit integer default 3
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child record;
  v_active_version text;
  v_as_of timestamptz;
begin
  -- 1. Parameter validation (reject invalid inputs; never clamp)
  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 3 then
    raise exception 'Candidate limit must be between 1 and 3' using errcode = '22000';
  end if;

  if p_subject_key is not null
     and p_subject_key not in ('math', 'english', 'literature', 'science', 'other') then
    raise exception 'Invalid subject_key' using errcode = '22000';
  end if;

  -- 2. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 3. Server-derived tenancy & active child check
  select id, family_id, school_grade
  into v_child
  from public.child_profiles
  where id = p_child_id
    and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  -- 4. Family adult or exact paired-child authorization
  if not (
    private.is_active_family_adult(v_child.family_id)
    or private.is_active_child_device(v_child.family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 5. Active catalog check
  select cv.version
  into v_active_version
  from public.learning_catalog_versions cv
  where cv.status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  -- 6. Single clock capture & delegation
  v_as_of := transaction_timestamp();
  return private.get_next_challenge_candidates_at(p_child_id, p_subject_key, p_limit, v_as_of);
end;
$$;

revoke all on function public.get_next_challenge_candidates(uuid, text, integer) from public, anon;
grant execute on function public.get_next_challenge_candidates(uuid, text, integer) to authenticated, service_role;
