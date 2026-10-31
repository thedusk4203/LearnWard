begin;
select plan(2);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true);

select is(auth.uid(), '11111111-1111-1111-1111-111111111111'::uuid, 'auth.uid() matches simulated claims');
select is(auth.role(), 'authenticated', 'auth.role() is authenticated');

select * from finish();
rollback;
