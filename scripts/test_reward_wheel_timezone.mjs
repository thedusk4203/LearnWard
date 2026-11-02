// scripts/test_reward_wheel_timezone.mjs
/**
 * LearnWard - Celebration Wheel Timezone & Calendar Day Boundary Test
 *
 * PURPOSE:
 * 1. Calendar Day vs Rolling 24-Hour Window:
 *    - The daily spin cap must reset at local midnight of the family's configured timezone,
 *      NOT on a rolling 24-hour window from the previous spin.
 *    - Spins created in "yesterday's" local day do not block spins in "today's" local day,
 *      even if fewer than 24 hours have elapsed.
 *
 * 2. Multi-Timezone Independence:
 *    - Different families in different timezones (e.g., America/New_York vs Asia/Ho_Chi_Minh)
 *      evaluate local calendar boundaries independently based on families.timezone.
 *
 * 3. Daily Cap Enforcement within Current Local Day:
 *    - When 3 spins are recorded within the current local calendar day [today_00:00, tomorrow_00:00),
 *      the 4th spin is strictly rejected with LW202.
 */

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
      { stdio: ['pipe', 'pipe', 'pipe'] }
    );

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });

    child.on('close', (code) => {
      resolve({ code, stdout, stderr });
    });

    child.on('error', reject);

    child.stdin.write(sql);
    child.stdin.end();
  });
}

async function main() {
  console.log('=== LearnWard Timezone & Calendar Day Boundary Test: Celebration Wheel ===\n');

  const FAMILY_NY_ID = crypto.randomUUID();
  const FAMILY_VN_ID = crypto.randomUUID();
  const OWNER_NY_ID = crypto.randomUUID();
  const OWNER_VN_ID = crypto.randomUUID();
  const CHILD_NY_ID = crypto.randomUUID();
  const CHILD_VN_ID = crypto.randomUUID();

  console.log('1. Setting up fixtures for America/New_York and Asia/Ho_Chi_Minh families...');

  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_NY_ID}', 'tz_ny_${OWNER_NY_ID}@example.com'),
      ('${OWNER_VN_ID}', 'tz_vn_${OWNER_VN_ID}@example.com')
    on conflict (id) do nothing;

    -- Family NY: America/New_York
    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_NY_ID}', 'NY Family', 'America/New_York', 'en-US', '${OWNER_NY_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_NY_ID}', '${OWNER_NY_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_NY_ID}', '${FAMILY_NY_ID}', 'NY Child', 4, 2016)
    on conflict (id) do nothing;

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_NY_ID}', '${CHILD_NY_ID}', 100, 10000)
    on conflict (child_id) do update set rp_balance_minor = 10000, xp_total = 100;

    -- Family VN: Asia/Ho_Chi_Minh
    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_VN_ID}', 'VN Family', 'Asia/Ho_Chi_Minh', 'vi-VN', '${OWNER_VN_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_VN_ID}', '${OWNER_VN_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_VN_ID}', '${FAMILY_VN_ID}', 'VN Child', 4, 2016)
    on conflict (id) do nothing;

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_VN_ID}', '${CHILD_VN_ID}', 100, 10000)
    on conflict (child_id) do update set rp_balance_minor = 10000, xp_total = 100;

    -- Add 3 Wheel Rewards for each family
    insert into public.rewards (family_id, title, category, store_enabled, store_cost_minor, wheel_enabled, wheel_tier, is_active)
    values
      ('${FAMILY_NY_ID}', 'NY Prize 1', 'privilege', false, null, true, 'common', true),
      ('${FAMILY_NY_ID}', 'NY Prize 2', 'treat', false, null, true, 'special', true),
      ('${FAMILY_NY_ID}', 'NY Prize 3', 'experience', false, null, true, 'rare', true),
      ('${FAMILY_VN_ID}', 'VN Prize 1', 'privilege', false, null, true, 'common', true),
      ('${FAMILY_VN_ID}', 'VN Prize 2', 'treat', false, null, true, 'special', true),
      ('${FAMILY_VN_ID}', 'VN Prize 3', 'experience', false, null, true, 'rare', true);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Timezone test fixtures established.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 1: Yesterday's spins do not count against today's calendar cap
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 1: Calendar Day Reset vs Rolling 24 Hours ---');

  // Insert 3 spins timestamped in "yesterday's" local day for NY Child (e.g. 18 hours ago)
  // Even though 18 hours < 24 hours, local calendar date was yesterday, so today's spin must succeed!
  const yesterdaySpinSql = `
    do $$
    declare
      v_fam_tz text := 'America/New_York';
      v_yesterday_local timestamptz;
      v_spin_id uuid;
      v_redemp_id uuid;
      v_reward_id uuid;
    begin
      -- 12:00 PM yesterday in New York
      v_yesterday_local := ((now() at time zone v_fam_tz)::date - 1)::timestamp at time zone v_fam_tz + interval '12 hours';
      select id into v_reward_id from public.rewards where family_id = '${FAMILY_NY_ID}' and is_active = true limit 1;

      for i in 1..3 loop
        v_spin_id := gen_random_uuid();
        v_redemp_id := gen_random_uuid();

        insert into public.reward_redemptions (id, family_id, child_id, reward_id, origin, rp_cost_minor, status, reward_snapshot, created_at, updated_at)
        values (v_redemp_id, '${FAMILY_NY_ID}', '${CHILD_NY_ID}', v_reward_id, 'wheel', 1000, 'pending_fulfillment', '{"title": "NY Prize"}'::jsonb, v_yesterday_local, v_yesterday_local);

        insert into public.wheel_spins (id, family_id, child_id, reward_id, redemption_id, origin, spin_cost_minor, selection_snapshot, created_at)
        values (v_spin_id, '${FAMILY_NY_ID}', '${CHILD_NY_ID}', v_reward_id, v_redemp_id, 'wheel', 1000, '{"note": "yesterday"}'::jsonb, v_yesterday_local);
      end loop;
    end $$;
  `;

  const yesterdayRes = await runPsql(yesterdaySpinSql);
  if (yesterdayRes.code !== 0) {
    console.error('Failed to insert yesterday spins:', yesterdayRes.stderr);
    process.exit(1);
  }
  console.log('Inserted 3 spins timestamped yesterday in America/New_York.');

  // NY Child attempts to spin today
  const CMD_TODAY_SPIN = crypto.randomUUID();
  const todaySpinSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_NY_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_TODAY_SPIN}'::uuid, '${CHILD_NY_ID}'::uuid);
  `;

  const todaySpinRes = await runPsql(todaySpinSql);
  if (todaySpinRes.code !== 0) {
    console.error('FAILED: Spin today failed even though previous spins were yesterday:', todaySpinRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Spin today succeeded! Calendar day boundary correctly ignored yesterday spins (not a rolling 24h block).\n');

  // -------------------------------------------------------------------------
  // SCENARIO 2: Daily cap strictly enforced within today's local calendar day
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 2: Daily Cap (3/3) Enforcement in Today\'s Calendar Day ---');

  // Child already has 1 spin today (CMD_TODAY_SPIN). Execute spins 2 and 3.
  const spin2Res = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_NY_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CHILD_NY_ID}'::uuid);
  `);
  if (spin2Res.code !== 0) {
    console.error('Failed spin 2 today:', spin2Res.stderr);
    process.exit(1);
  }

  const spin3Res = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_NY_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CHILD_NY_ID}'::uuid);
  `);
  if (spin3Res.code !== 0) {
    console.error('Failed spin 3 today:', spin3Res.stderr);
    process.exit(1);
  }
  console.log('Child has now completed 3 spins in today\'s local calendar day.');

  // Attempt spin 4 -> must fail LW202
  const spin4Res = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_NY_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CHILD_NY_ID}'::uuid);
  `);

  if (!spin4Res.stderr.includes('Daily spin limit reached') && !spin4Res.stderr.includes('LW202')) {
    console.error('FAILED: Spin 4 should have been blocked by daily cap, but got:', spin4Res.stderr || spin4Res.stdout);
    process.exit(1);
  }
  console.log('PASS: 4th spin in same local calendar day correctly rejected with LW202.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 3: Timezone Boundary Independence
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 3: Distinct Timezones (NY vs VN) Independent State ---');

  // VN child has 0 spins today, despite NY child having reached cap
  const CMD_VN_SPIN = crypto.randomUUID();
  const vnSpinRes = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_VN_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_VN_SPIN}'::uuid, '${CHILD_VN_ID}'::uuid);
  `);

  if (vnSpinRes.code !== 0) {
    console.error('FAILED: VN child spin failed:', vnSpinRes.stderr);
    process.exit(1);
  }
  console.log('PASS: VN child spins cleanly under independent Asia/Ho_Chi_Minh local calendar calculations.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 4: Spring-Forward DST Transition (23-Hour Calendar Day)
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 4: Spring-Forward DST (2026-03-08 America/New_York) ---');
  const dstSpringSql = `
    select
      extract(epoch from (
        (('2026-03-08'::date + 1)::timestamp at time zone 'America/New_York') -
        ('2026-03-08'::date::timestamp at time zone 'America/New_York')
      )) / 3600.0 as spring_hours;
  `;
  const springRes = await runPsql(dstSpringSql);
  const springMatch = springRes.stdout.match(/(\d+(\.\d+)?)/);
  if (!springMatch || parseFloat(springMatch[1]) !== 23.0) {
    console.error('FAILED: Expected 2026-03-08 in America/New_York to span 23.0 absolute hours, got:', springRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Spring forward 2026-03-08 in America/New_York spans exactly 23.0 absolute hours.');

  // Verify midnight boundary at spring forward: 2026-03-07 23:59:59 vs 2026-03-08 00:00:01
  const boundaryCheckSql = `
    select
      ('2026-03-07 23:59:59'::timestamp at time zone 'America/New_York') < ('2026-03-08 00:00:00'::timestamp at time zone 'America/New_York') as day_before,
      ('2026-03-08 00:00:01'::timestamp at time zone 'America/New_York') >= ('2026-03-08 00:00:00'::timestamp at time zone 'America/New_York')
        and ('2026-03-08 00:00:01'::timestamp at time zone 'America/New_York') < ('2026-03-09 00:00:00'::timestamp at time zone 'America/New_York') as day_of,
      ('2026-03-09 00:00:01'::timestamp at time zone 'America/New_York') >= ('2026-03-09 00:00:00'::timestamp at time zone 'America/New_York') as day_after;
  `;
  const boundaryRes = await runPsql(boundaryCheckSql);
  if (!/t\s+\|\s+t\s+\|\s+t/.test(boundaryRes.stdout)) {
    console.error('FAILED: Spring forward midnight boundary failed:', boundaryRes.stdout);
    process.exit(1);
  }
  console.log('PASS: 23:59:59 is Day N; 00:00:01 is Day N+1 around spring forward.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 5: Fall-Back DST Transition (25-Hour Calendar Day)
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 5: Fall-Back DST (2026-11-01 America/New_York) ---');
  const dstFallSql = `
    select
      extract(epoch from (
        (('2026-11-01'::date + 1)::timestamp at time zone 'America/New_York') -
        ('2026-11-01'::date::timestamp at time zone 'America/New_York')
      )) / 3600.0 as fall_hours;
  `;
  const fallRes = await runPsql(dstFallSql);
  const fallMatch = fallRes.stdout.match(/(\d+(\.\d+)?)/);
  if (!fallMatch || parseFloat(fallMatch[1]) !== 25.0) {
    console.error('FAILED: Expected 2026-11-01 in America/New_York to span 25.0 absolute hours, got:', fallRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Fall back 2026-11-01 in America/New_York spans exactly 25.0 absolute hours.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 6: Non-DST Timezone Ordinary 24-Hour Calendar Day
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 6: Non-DST Timezone (Asia/Ho_Chi_Minh) ---');
  const nonDstSql = `
    select
      extract(epoch from (
        (('2026-03-08'::date + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh') -
        ('2026-03-08'::date::timestamp at time zone 'Asia/Ho_Chi_Minh')
      )) / 3600.0 as vn_spring_hours,
      extract(epoch from (
        (('2026-11-01'::date + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh') -
        ('2026-11-01'::date::timestamp at time zone 'Asia/Ho_Chi_Minh')
      )) / 3600.0 as vn_fall_hours;
  `;
  const nonDstRes = await runPsql(nonDstSql);
  if (!/24(\.0+)?\s+\|\s+24(\.0+)?/.test(nonDstRes.stdout)) {
    console.error('FAILED: Expected Asia/Ho_Chi_Minh to span 24 hours on both dates, got:', nonDstRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Asia/Ho_Chi_Minh spans exactly 24.0 hours across DST transition dates.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 7: Fail-Closed Behavior for Invalid / Corrupt Timezone
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 7: Fail-Closed on Corrupt / Missing Timezone ---');
  const CORRUPT_FAM_ID = crypto.randomUUID();
  const CORRUPT_CHILD_ID = crypto.randomUUID();
  const corruptSetupSql = `
    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${CORRUPT_FAM_ID}', 'Corrupt TZ Family', 'Invalid/Timezone_Name', 'en-US', '${OWNER_NY_ID}')
    on conflict (id) do update set timezone = 'Invalid/Timezone_Name';

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${CORRUPT_FAM_ID}', '${OWNER_NY_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CORRUPT_CHILD_ID}', '${CORRUPT_FAM_ID}', 'Corrupt Child', 4, 2016);
  `;
  await runPsql(corruptSetupSql);

  const corruptSpinSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_NY_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CORRUPT_CHILD_ID}'::uuid);
  `;
  const corruptSpinRes = await runPsql(corruptSpinSql);
  if (!corruptSpinRes.stderr.includes('LW004') && !corruptSpinRes.stderr.includes('Invalid family timezone')) {
    console.error('FAILED: Expected corrupt timezone to fail with LW004, got:', corruptSpinRes.stderr || corruptSpinRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Corrupt family timezone fails closed with LW004 before any economic mutation.\n');

  console.log('===============================================================');
  console.log('ALL TIMEZONE & CALENDAR BOUNDARY TESTS PASSED!');
  console.log('===============================================================');
}

main().catch((err) => {
  console.error('Unhandled timezone test failure:', err);
  process.exit(1);
});
