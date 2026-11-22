-- pega28 · Etapas 4 e 5 · rode TUDO de uma vez no SQL Editor do Supabase (Run).
-- Não apaga nada: só adiciona colunas, tabelas e funções, e deixa as permissões mais seguras.

-- 1) Novas colunas
alter table public.games
  add column if not exists center_lat double precision,
  add column if not exists center_lng double precision,
  add column if not exists started_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists winner text,
  add column if not exists last_ping_n int not null default 0;
alter table public.players add column if not exists status text not null default 'vivo';

-- 2) Tabelas privadas (nenhum jogador consegue ler direto; só pelas funções abaixo)
create table if not exists public.positions (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null,
  lat double precision not null, lng double precision not null,
  updated_at timestamptz not null default now(),
  out_since timestamptz,
  primary key (game_id, user_id)
);
create table if not exists public.pings (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null, n int not null,
  lat double precision not null, lng double precision not null,
  at timestamptz not null default now(),
  primary key (game_id, user_id, n)
);
create table if not exists public.captures (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  hunter_id uuid not null, target_id uuid not null,
  status text not null default 'pendente',
  created_at timestamptz not null default now()
);
alter table public.positions enable row level security;
alter table public.pings enable row level security;
alter table public.captures enable row level security;
revoke all on public.positions, public.pings, public.captures from anon, authenticated;

-- 3) Permissões mais apertadas nas tabelas que já existiam
drop policy if exists games_select on public.games;
create policy games_select on public.games for select to authenticated
  using (host_id = auth.uid() or public.in_game(id));
drop policy if exists players_update_host on public.players;
revoke insert, update on public.players from authenticated;
grant insert (game_id, nickname) on public.players to authenticated;
revoke insert, update on public.games from authenticated;
grant insert (code, settings) on public.games to authenticated;

-- 4) Funções auxiliares
create or replace function public.dist_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
    + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2)));
$$;

create or replace function public.zone_r(g public.games) returns double precision
language sql stable as $$
  select greatest(30, (g.settings->>'raio')::float
    * power(1 - (g.settings->>'encolhe_pct')::float / 100,
        floor(greatest(0, extract(epoch from (now() - g.started_at)) - (g.settings->>'vantagem')::float * 60)
          / ((g.settings->>'encolhe_cada')::float * 60))));
$$;

-- 5) Entrar numa partida pelo código
create or replace function public.join_game(p_code text, p_nick text) returns uuid
language plpgsql security definer set search_path = public as $$
declare g games;
begin
  if auth.uid() is null then raise exception 'Faça login'; end if;
  if char_length(trim(p_nick)) = 0 then raise exception 'Digite um apelido.'; end if;
  select * into g from games where code = upper(trim(p_code));
  if not found then raise exception 'Código não encontrado.'; end if;
  if g.status <> 'lobby' then raise exception 'Essa partida já começou.'; end if;
  insert into players (game_id, nickname) values (g.id, left(trim(p_nick), 20))
    on conflict (game_id, user_id) do nothing;
  return g.id;
end $$;

-- 6) Equipes (só o anfitrião, só na sala de espera)
create or replace function public.set_team(p_pid uuid, p_team text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_team not in ('cacador', 'fugitivo') then raise exception 'Equipe inválida'; end if;
  update players p set team = p_team from games g
   where p.id = p_pid and g.id = p.game_id and g.host_id = auth.uid() and g.status = 'lobby';
end $$;

create or replace function public.random_teams(p_gid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g games;
begin
  select * into g from games where id = p_gid and host_id = auth.uid() and status = 'lobby';
  if not found then raise exception 'Só o anfitrião pode sortear'; end if;
  with o as (select id, row_number() over (order by random()) rn, count(*) over () total from players where game_id = p_gid)
  update players p set team = case when o.rn <= least(greatest((g.settings->>'cacadores')::int, 1), o.total - 1)
                                   then 'cacador' else 'fugitivo' end
  from o where p.id = o.id;
end $$;

-- 7) Iniciar (o centro da zona é a posição do anfitrião neste momento)
create or replace function public.start_game(p_gid uuid, p_lat double precision, p_lng double precision) returns void
language plpgsql security definer set search_path = public as $$
declare g games; nh int; nf int; nn int;
begin
  select * into g from games where id = p_gid and host_id = auth.uid() for update;
  if not found then raise exception 'Só o anfitrião pode iniciar'; end if;
  if g.status <> 'lobby' then raise exception 'A partida já começou'; end if;
  select count(*) filter (where team = 'cacador'), count(*) filter (where team = 'fugitivo'), count(*) filter (where team is null)
    into nh, nf, nn from players where game_id = p_gid;
  if nn > 0 then raise exception 'Todos precisam ter uma equipe'; end if;
  if nh < 1 or nf < 1 then raise exception 'Precisa de ao menos 1 caçador e 1 fugitivo'; end if;
  update games set status = 'running', center_lat = p_lat, center_lng = p_lng, started_at = now(), last_ping_n = 0,
    ends_at = now() + (g.settings->>'total')::float * interval '1 minute'
  where id = p_gid;
end $$;

-- 8) Receber a posição de quem joga (o servidor decide se está fora da zona)
create or replace function public.send_position(p_gid uuid, p_lat double precision, p_lng double precision) returns void
language plpgsql security definer set search_path = public as $$
declare g games; v_out boolean;
begin
  select * into g from games where id = p_gid;
  if not found or g.status <> 'running' then return; end if;
  if not exists (select 1 from players where game_id = p_gid and user_id = auth.uid() and status = 'vivo') then return; end if;
  v_out := now() > g.started_at + (g.settings->>'vantagem')::float * interval '1 minute'
           and dist_m(g.center_lat, g.center_lng, p_lat, p_lng) > zone_r(g);
  insert into positions (game_id, user_id, lat, lng, out_since)
    values (p_gid, auth.uid(), p_lat, p_lng, case when v_out then now() end)
  on conflict (game_id, user_id) do update
    set lat = excluded.lat, lng = excluded.lng, updated_at = now(),
        out_since = case when v_out then coalesce(positions.out_since, now()) else null end;
end $$;

-- 9) Relógio da partida: pings, eliminações e fim (sempre calculado no servidor)
create or replace function public.tick(p_gid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g games; v_play timestamptz; v_n int; v_alive int; v_win text;
begin
  if not exists (select 1 from players where game_id = p_gid and user_id = auth.uid()) then return; end if;
  select * into g from games where id = p_gid for update;
  if g.status <> 'running' then return; end if;
  v_play := g.started_at + (g.settings->>'vantagem')::float * interval '1 minute';
  if now() >= v_play then
    v_n := floor(extract(epoch from (now() - v_play)) / ((g.settings->>'ping')::float * 60));
    if v_n > g.last_ping_n then
      insert into pings (game_id, user_id, n, lat, lng)
        select p_gid, ps.user_id, v_n, ps.lat, ps.lng from positions ps
        join players pl on pl.game_id = ps.game_id and pl.user_id = ps.user_id
        where ps.game_id = p_gid and pl.team = 'fugitivo' and pl.status = 'vivo'
      on conflict do nothing;
      update games set last_ping_n = v_n where id = p_gid;
    end if;
    update players pl set status = 'eliminado' from positions ps
     where ps.game_id = pl.game_id and ps.user_id = pl.user_id and pl.game_id = p_gid
       and pl.team = 'fugitivo' and pl.status = 'vivo' and ps.out_since is not null
       and now() - ps.out_since >= (g.settings->>'fora_elimina')::float * interval '1 second';
  end if;
  select count(*) into v_alive from players where game_id = p_gid and team = 'fugitivo' and status = 'vivo';
  if v_alive = 0 then v_win := 'cacadores';
  elsif now() >= g.ends_at then v_win := 'fugitivos'; end if;
  if v_win is not null then
    update games set status = 'finished', winner = v_win where id = p_gid;
    delete from positions where game_id = p_gid;  -- apaga as localizações ao fim
    delete from pings where game_id = p_gid;
  end if;
end $$;

-- 10) Capturas: caçador pede, fugitivo confirma (ou o anfitrião valida)
create or replace function public.request_capture(p_gid uuid, p_target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from games where id = p_gid and status = 'running')
     or not exists (select 1 from players where game_id = p_gid and user_id = auth.uid() and team = 'cacador' and status = 'vivo')
     or not exists (select 1 from players where game_id = p_gid and user_id = p_target and team = 'fugitivo' and status = 'vivo')
  then raise exception 'Captura inválida'; end if;
  if exists (select 1 from captures where game_id = p_gid and hunter_id = auth.uid() and target_id = p_target and status = 'pendente') then return; end if;
  insert into captures (game_id, hunter_id, target_id) values (p_gid, auth.uid(), p_target);
end $$;

create or replace function public.answer_capture(p_id uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c captures;
begin
  select * into c from captures where id = p_id and status = 'pendente' for update;
  if not found then return; end if;
  if not (c.target_id = auth.uid() or exists (select 1 from games where id = c.game_id and host_id = auth.uid())) then
    raise exception 'Sem permissão'; end if;
  update captures set status = case when p_accept then 'confirmada' else 'recusada' end where id = p_id;
  if p_accept then
    update players set status = 'capturado' where game_id = c.game_id and user_id = c.target_id and status = 'vivo';
    delete from positions where game_id = c.game_id and user_id = c.target_id;
    perform tick(c.game_id);
  end if;
end $$;

-- 11) Foto da partida para quem está jogando (aqui ficam as regras de quem vê quem)
create or replace function public.snapshot(p_gid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g games; me players;
begin
  select * into me from players where game_id = p_gid and user_id = auth.uid();
  if not found then raise exception 'Você não está nesta partida'; end if;
  perform tick(p_gid);
  select * into g from games where id = p_gid;
  select * into me from players where game_id = p_gid and user_id = auth.uid();
  return jsonb_build_object(
    'now', now(), 'code', g.code, 'host_id', g.host_id, 'status', g.status, 'winner', g.winner,
    'started_at', g.started_at, 'ends_at', g.ends_at, 'settings', g.settings,
    'center', jsonb_build_object('lat', g.center_lat, 'lng', g.center_lng),
    'radius', case when g.status = 'running' then zone_r(g) end,
    'me', jsonb_build_object('id', me.id, 'user_id', me.user_id, 'team', me.team, 'status', me.status),
    'my_out_since', (select out_since from positions where game_id = p_gid and user_id = auth.uid()),
    'players', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'user_id', user_id, 'nickname', nickname, 'team', team, 'status', status) order by created_at), '[]'::jsonb) from players where game_id = p_gid),
    'captures', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'hunter_id', c.hunter_id, 'target_id', c.target_id, 'hunter_nick', h.nickname, 'target_nick', t.nickname)), '[]'::jsonb)
                 from captures c join players h on h.game_id = c.game_id and h.user_id = c.hunter_id
                 join players t on t.game_id = c.game_id and t.user_id = c.target_id
                 where c.game_id = p_gid and c.status = 'pendente'
                   and (c.hunter_id = auth.uid() or c.target_id = auth.uid() or g.host_id = auth.uid())),
    'visible', case when g.status <> 'running' then '[]'::jsonb else (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        -- caçadores veem os colegas de equipe ao vivo
        select jsonb_build_object('user_id', ps.user_id, 'lat', ps.lat, 'lng', ps.lng, 'kind', 'time') as x
          from positions ps join players pl on pl.game_id = ps.game_id and pl.user_id = ps.user_id
         where me.team = 'cacador' and ps.game_id = p_gid and pl.team = 'cacador' and pl.status = 'vivo' and ps.user_id <> auth.uid()
        union all
        -- caçadores veem só a "foto" do último ping de cada fugitivo livre
        select * from (
          select distinct on (pg.user_id) jsonb_build_object('user_id', pg.user_id, 'lat', pg.lat, 'lng', pg.lng, 'kind', 'ping', 'at', pg.at)
            from pings pg join players pl on pl.game_id = pg.game_id and pl.user_id = pg.user_id
           where me.team = 'cacador' and pg.game_id = p_gid and pl.status = 'vivo'
           order by pg.user_id, pg.n desc) q
        union all
        -- fugitivo fora da zona há tempo demais aparece ao vivo
        select jsonb_build_object('user_id', ps.user_id, 'lat', ps.lat, 'lng', ps.lng, 'kind', 'ao_vivo')
          from positions ps join players pl on pl.game_id = ps.game_id and pl.user_id = ps.user_id
         where me.team = 'cacador' and ps.game_id = p_gid and pl.team = 'fugitivo' and pl.status = 'vivo'
           and ps.out_since is not null and now() - ps.out_since >= (g.settings->>'fora_revela')::float * interval '1 second'
      ) s) end)
  ;
end $$;

-- 12) Quem pode chamar o quê (somente usuários logados)
revoke all on function public.join_game(text, text), public.set_team(uuid, text), public.random_teams(uuid),
  public.start_game(uuid, double precision, double precision), public.send_position(uuid, double precision, double precision),
  public.tick(uuid), public.request_capture(uuid, uuid), public.answer_capture(uuid, boolean), public.snapshot(uuid)
  from public, anon;
grant execute on function public.join_game(text, text), public.set_team(uuid, text), public.random_teams(uuid),
  public.start_game(uuid, double precision, double precision), public.send_position(uuid, double precision, double precision),
  public.tick(uuid), public.request_capture(uuid, uuid), public.answer_capture(uuid, boolean), public.snapshot(uuid)
  to authenticated;
