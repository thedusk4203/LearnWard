// scripts/verify_auth_e2e_local.mjs
/**
 * Local Supabase Auth Return Path Verification
 *
 * Exercises the real local Supabase stack:
 * 1. Requests magic link via Supabase Auth API with redirect_to=com.learnward.app://auth-callback
 * 2. Queries local Mailpit API (port 45324) to retrieve the delivered email
 * 3. Inspects and extracts the magic link containing the verification token
 * 4. Exchanges the token with Supabase Auth to establish a real authenticated session
 * 5. Calls public.create_family RPC using the session JWT to verify adult tenancy creation
 */

const API_URL = 'http://127.0.0.1:45321';
const MAILPIT_URL = 'http://127.0.0.1:45324';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const TEST_EMAIL = `parent_${Date.now()}@learnward.local`;

async function main() {
  console.log('=== Step 1: Requesting Magic Link from Local Supabase Auth ===');
  console.log(`Target Email: ${TEST_EMAIL}`);
  console.log('Redirect URI: com.learnward.app://auth-callback');

  const otpRes = await fetch(`${API_URL}/auth/v1/otp`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email: TEST_EMAIL,
      create_user: true,
      data: {},
    }),
  });

  if (!otpRes.ok) {
    const err = await otpRes.text();
    throw new Error(`OTP request failed: ${otpRes.status} ${err}`);
  }
  console.log('Magic link request accepted by Supabase Auth (HTTP 200).');

  console.log('\n=== Step 2: Inspecting Mailpit for Sent Email ===');
  await new Promise((r) => setTimeout(r, 1000)); // Brief pause for Mailpit delivery

  const mailRes = await fetch(`${MAILPIT_URL}/api/v1/messages`);
  if (!mailRes.ok) {
    throw new Error(`Failed to query Mailpit: ${mailRes.status}`);
  }
  const mailData = await mailRes.json();
  const msgSummary = mailData.messages?.find((m) =>
    m.To?.some((t) => t.Address === TEST_EMAIL)
  );

  if (!msgSummary) {
    throw new Error(`No email found in Mailpit for ${TEST_EMAIL}`);
  }
  console.log(`Found email in Mailpit! Message ID: ${msgSummary.ID}, Subject: ${msgSummary.Subject}`);

  const msgDetailRes = await fetch(`${MAILPIT_URL}/api/v1/message/${msgSummary.ID}`);
  const msgDetail = await msgDetailRes.json();
  const bodyText = msgDetail.Text || msgDetail.HTML || '';

  // Extract link
  const linkMatch = bodyText.match(/https?:\/\/[^\s"'<>]+/);
  if (!linkMatch) {
    throw new Error('No link found in email body');
  }
  const rawMagicLink = linkMatch[0];
  console.log(`Delivered Magic Link: ${rawMagicLink}`);

  // Parse verify URL
  const parsedUrl = new URL(rawMagicLink);
  const token = parsedUrl.searchParams.get('token');
  const type = parsedUrl.searchParams.get('type') || 'magiclink';
  const redirectTo = parsedUrl.searchParams.get('redirect_to');

  console.log(`Extracted Token: ${token ? '***' + token.slice(-6) : 'missing'}`);
  console.log(`Verified Redirect-To in Link: ${redirectTo}`);

  if (redirectTo !== 'com.learnward.app://auth-callback') {
    throw new Error(`Redirect URI mismatch! Expected com.learnward.app://auth-callback, got ${redirectTo}`);
  }

  console.log('\n=== Step 3: Following Magic Link Verification URL ===');
  // When a user taps the magic link in their mobile mail client, it opens the verify URL:
  const getVerifyRes = await fetch(rawMagicLink, {
    method: 'GET',
    redirect: 'manual', // do not follow redirect to custom URL scheme
  });

  const locationHeader = getVerifyRes.headers.get('location');
  console.log(`Verify HTTP status: ${getVerifyRes.status}`);
  console.log(`Redirect Location: ${locationHeader}`);

  if (!locationHeader || !locationHeader.startsWith('com.learnward.app://auth-callback')) {
    throw new Error(`Expected redirect to mobile app scheme com.learnward.app://auth-callback, got: ${locationHeader}`);
  }

  // Extract access_token from callback URL fragment (#access_token=...&refresh_token=...)
  const fragment = locationHeader.split('#')[1] || '';
  const params = new URLSearchParams(fragment);
  const accessToken = params.get('access_token');

  if (!accessToken) {
    throw new Error(`No access_token found in callback URL fragment: ${locationHeader}`);
  }
  console.log(`Successfully acquired session access_token from mobile deep-link callback!`);

  console.log('\n=== Step 4: Calling public.create_family RPC with Authenticated Session ===');
  const rpcRes = await fetch(`${API_URL}/rest/v1/rpc/create_family`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
    },
    body: JSON.stringify({
      p_name: 'Verified Test Family',
      p_timezone: 'America/New_York',
      p_locale: 'en-US',
    }),
  });

  if (!rpcRes.ok) {
    const err = await rpcRes.text();
    throw new Error(`create_family RPC failed: ${rpcRes.status} ${err}`);
  }

  const familyResult = await rpcRes.json();
  console.log('create_family succeeded atomically:');
  console.log(familyResult);

  console.log('\n[PASS] Real local Supabase auth and family creation loop verified successfully!');
}

main().catch((err) => {
  console.error('[FAIL]', err);
  process.exit(1);
});
