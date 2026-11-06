-- ===========================================================================
-- LearnWard Migration: Phase 6 Slice 3 - Family Data Export & Portability
--
-- Formal Specification:
-- - ACCEPTED ADR 0008: Pilot Hardening, Security, and Governance Boundaries
-- - Phase 6 Detailed Design §4.3.4: Schema-Verified Family Data Portability RPC
--
-- Architectural & Governance Boundaries:
-- 1. Data Minimization & Media Boundary:
--    The export payload includes strictly structured metadata and relative Storage
--    paths for media (assessment evidence), NEVER base64-encoded binary image bytes.
--    This prevents unbounded payload memory allocation and network exhaustion.
--    Binary evidence assets remain protected in private Storage buckets accessible
--    only via authenticated signed URL sessions.
--
-- 2. Compliance & Legal Notice:
--    This RPC delivers structured operational, educational, and financial data
--    portability for the requested tenant. It does NOT constitute a complete GDPR
--    Article 20, COPPA, or CCPA legal compliance certificate. Comprehensive compliance
--    encompasses operational server access logs, third-party authentication logs,
--    and organizational data processing agreements handled outside this database tier.
-- ===========================================================================

create or replace function public.export_family_data_json(p_family_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_export jsonb;
begin
  -- 1. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_family_id is null then
    raise exception 'Family ID is required' using errcode = '22000';
  end if;

  -- 2. Authorization check: caller must be an active adult/owner in the target family
  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Unauthorized to export family data' using errcode = '42501';
  end if;

  -- 3. Construct structured export payload using strictly verified columns
  select jsonb_build_object(
    'export_version', 1,
    'exported_at', now(),
    'family', (
      select jsonb_build_object(
        'id', id,
        'name', name,
        'timezone', timezone,
        'locale', locale,
        'created_at', created_at,
        'archived_at', archived_at
      )
      from public.families
      where id = p_family_id
    ),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'display_name', display_name,
        'school_grade', school_grade,
        'birth_year', birth_year,
        'avatar_key', avatar_key,
        'status', status,
        'created_at', created_at,
        'archived_at', archived_at
      ) order by created_at)
      from public.child_profiles
      where family_id = p_family_id
    ), '[]'::jsonb),
    'child_balances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id,
        'xp_total', xp_total,
        'rp_balance_minor', rp_balance_minor,
        'updated_at', updated_at
      ) order by child_id)
      from public.child_balances
      where family_id = p_family_id
    ), '[]'::jsonb),
    'assessments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'subject_key', subject_key,
        'subject', subject,
        'title', title,
        'assessment_type', assessment_type,
        'difficulty', difficulty,
        'raw_score', raw_score,
        'max_score', max_score,
        'normalized_score', normalized_score,
        'entry_context', entry_context,
        'status', status,
        'occurred_at', occurred_at,
        'version', version,
        'created_at', created_at
      ) order by occurred_at)
      from public.assessments
      where family_id = p_family_id and status != 'draft'
    ), '[]'::jsonb),
    'assessment_evidence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'assessment_id', assessment_id,
        'storage_path', storage_path,
        'media_type', media_type,
        'file_size_bytes', file_size_bytes,
        'created_at', created_at
      ) order by created_at)
      from public.assessment_evidence
      where family_id = p_family_id
    ), '[]'::jsonb),
    'verified_learning_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'assessment_id', assessment_id,
        'subject_key', subject_key,
        'subject', subject,
        'title', title,
        'assessment_type', assessment_type,
        'difficulty', difficulty,
        'raw_score', raw_score,
        'max_score', max_score,
        'normalized_score', normalized_score,
        'evidence_count', evidence_count,
        'entry_context', entry_context,
        'occurred_at', occurred_at,
        'verified_at', verified_at
      ) order by occurred_at)
      from public.verified_learning_events
      where family_id = p_family_id
    ), '[]'::jsonb),
    'mastery_states', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id,
        'learning_node_id', learning_node_id,
        'engine_version', engine_version,
        'mastery_score', mastery_score,
        'effective_evidence_count', effective_evidence_count,
        'distinct_assessment_count', distinct_assessment_count,
        'last_evidence_occurred_at', last_evidence_occurred_at,
        'last_verified_at', last_verified_at,
        'mastery_attained_at', mastery_attained_at,
        'updated_at', updated_at
      ) order by child_id, learning_node_id)
      from public.child_mastery_states
      where family_id = p_family_id
    ), '[]'::jsonb),
    'growth_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'assessment_id', assessment_id,
        'normalized_score', normalized_score,
        'baseline_score', baseline_score,
        'growth_delta', growth_delta,
        'historical_best', historical_best,
        'total_rp_minor', total_rp_minor,
        'xp_awarded', xp_awarded,
        'created_at', created_at
      ) order by created_at)
      from public.growth_events
      where family_id = p_family_id
    ), '[]'::jsonb),
    'xp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'amount', amount,
        'reason_code', reason_code,
        'source_type', source_type,
        'source_id', source_id,
        'created_at', created_at
      ) order by created_at)
      from public.xp_ledger
      where family_id = p_family_id
    ), '[]'::jsonb),
    'rp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'amount_minor', amount_minor,
        'reason_code', reason_code,
        'source_type', source_type,
        'source_id', source_id,
        'created_at', created_at
      ) order by created_at)
      from public.rp_ledger
      where family_id = p_family_id
    ), '[]'::jsonb),
    'reward_redemptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'reward_id', reward_id,
        'origin', origin,
        'rp_cost_minor', rp_cost_minor,
        'status', status,
        'reward_snapshot', reward_snapshot,
        'cancellation_reason', cancellation_reason,
        'fulfilled_at', fulfilled_at,
        'created_at', created_at
      ) order by created_at)
      from public.reward_redemptions
      where family_id = p_family_id
    ), '[]'::jsonb),
    'wheel_spins', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'reward_id', reward_id,
        'redemption_id', redemption_id,
        'origin', origin,
        'spin_cost_minor', spin_cost_minor,
        'selection_snapshot', selection_snapshot,
        'created_at', created_at
      ) order by created_at)
      from public.wheel_spins
      where family_id = p_family_id
    ), '[]'::jsonb)
  ) into v_export;

  return v_export;
end;
$$;

revoke execute on function public.export_family_data_json(uuid) from public, anon;
grant execute on function public.export_family_data_json(uuid) to authenticated;
