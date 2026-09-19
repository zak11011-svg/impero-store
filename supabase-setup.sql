-- ============================================================
-- COFFEE IMPERO  |  database setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to run more than once.
-- ============================================================

-- ---------- tables ----------

create table if not exists products (
  id            text primary key,
  name          text not null,
  model         text not null,
  pressure      text not null,
  battery       text not null,
  coffee_type   text not null,
  price         numeric(10,2) not null,
  stock         integer not null default 0,
  low_stock_at  integer not null default 3,
  active        boolean not null default true,
  sort_order    integer not null default 0,
  colors        jsonb not null default '[]'::jsonb,
  updated_at    timestamptz not null default now()
);

create table if not exists orders (
  id            uuid primary key default gen_random_uuid(),
  order_no      bigint generated always as identity,
  created_at    timestamptz not null default now(),
  customer_name text not null,
  phone         text not null,
  area          text not null,
  address       text not null,
  notes         text,
  total         numeric(10,2) not null,
  status        text not null default 'NEW'
);

create table if not exists order_items (
  id           bigint generated always as identity primary key,
  order_id     uuid not null references orders(id) on delete cascade,
  product_id   text not null,
  product_name text not null,
  color        text not null,
  qty          integer not null,
  unit_price   numeric(10,2) not null
);

create table if not exists stock_log (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  product_id  text not null,
  delta       integer not null,
  reason      text not null,
  note        text
);

create index if not exists orders_created_idx on orders (created_at desc);
create index if not exists stock_log_created_idx on stock_log (created_at desc);

-- ---------- seed the three machines ----------

insert into products (id, name, model, pressure, battery, coffee_type, price, stock, sort_order, colors) values
  ('core',  'Impero Core',  'Core',  '20 Bar', '9600mAh', '3-in-1', 239, 0, 1,
     '[{"name":"White","hex":"#EDEDEA","img":"assets/img/core-white.png"},
       {"name":"Black","hex":"#1A1A1A","img":"assets/img/core-black.png"},
       {"name":"Green","hex":"#2F4A34","img":"assets/img/core-green.png"}]'::jsonb),
  ('pro',   'Impero Pro',   'Pro',   '25 Bar', '9600mAh', '3-in-1', 279, 0, 2,
     '[{"name":"White","hex":"#EDEDEA","img":"assets/img/pro-white.png"},
       {"name":"Black","hex":"#1A1A1A","img":"assets/img/pro-black.png"}]'::jsonb),
  ('elite', 'Impero Elite', 'Elite', '25 Bar', '9600mAh', '4-in-1', 309, 0, 3,
     '[{"name":"White","hex":"#EDEDEA","img":"assets/img/elite-white.png"},
       {"name":"Black","hex":"#1A1A1A","img":"assets/img/elite-black.png"}]'::jsonb)
on conflict (id) do nothing;

-- ---------- place an order, atomically ----------
-- Checks stock, writes the order, decreases stock and logs it, all in one go.
-- Runs with elevated rights so the public can order without reading other data.

create or replace function place_order(
  p_name    text,
  p_phone   text,
  p_area    text,
  p_address text,
  p_notes   text,
  p_items   jsonb          -- [{"id":"core","color":"White","qty":1}, ...]
) returns table (order_id uuid, order_no bigint, total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  it        jsonb;
  prod      products%rowtype;
  v_qty     integer;
  v_total   numeric(10,2) := 0;
  v_order   orders%rowtype;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Name is required';
  end if;
  if p_phone is null or length(trim(p_phone)) < 6 then
    raise exception 'A valid phone number is required';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'No items in the order';
  end if;

  -- lock the rows so two orders cannot take the same last unit
  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, (it->>'qty')::int);
    select * into prod from products where id = it->>'id' for update;
    if not found then
      raise exception 'Unknown product %', it->>'id';
    end if;
    if not prod.active then
      raise exception '% is not available', prod.name;
    end if;
    if prod.stock < v_qty then
      raise exception 'Only % left of %', prod.stock, prod.name;
    end if;
    v_total := v_total + (prod.price * v_qty);
  end loop;

  insert into orders (customer_name, phone, area, address, notes, total)
  values (trim(p_name), trim(p_phone), trim(p_area), trim(p_address),
          nullif(trim(coalesce(p_notes,'')),''), v_total)
  returning * into v_order;

  for it in select * from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, (it->>'qty')::int);
    select * into prod from products where id = it->>'id';

    insert into order_items (order_id, product_id, product_name, color, qty, unit_price)
    values (v_order.id, prod.id, prod.name, coalesce(it->>'color',''), v_qty, prod.price);

    update products set stock = stock - v_qty, updated_at = now() where id = prod.id;

    insert into stock_log (product_id, delta, reason, note)
    values (prod.id, -v_qty, 'Order', 'Order #' || v_order.order_no);
  end loop;

  return query select v_order.id, v_order.order_no, v_order.total;
end;
$$;

revoke all on function place_order(text,text,text,text,text,jsonb) from public;
grant execute on function place_order(text,text,text,text,text,jsonb) to anon, authenticated;

-- ---------- stock adjustment used by the admin dashboard ----------

create or replace function adjust_stock(p_id text, p_delta integer, p_note text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_new integer;
begin
  if auth.role() <> 'authenticated' then
    raise exception 'Not authorised';
  end if;
  update products set stock = greatest(0, stock + p_delta), updated_at = now()
    where id = p_id returning stock into v_new;
  insert into stock_log (product_id, delta, reason, note)
    values (p_id, p_delta, case when p_delta >= 0 then 'Stock received' else 'Adjustment' end, p_note);
  return v_new;
end;
$$;

grant execute on function adjust_stock(text,integer,text) to authenticated;

-- ---------- table grants ----------

grant select on products to anon, authenticated;
grant all    on products, orders, order_items, stock_log to authenticated;
revoke all   on orders, order_items, stock_log from anon;

-- ---------- row level security ----------

alter table products    enable row level security;
alter table orders      enable row level security;
alter table order_items enable row level security;
alter table stock_log   enable row level security;

drop policy if exists products_read_all    on products;
drop policy if exists products_write_admin on products;
drop policy if exists orders_admin         on orders;
drop policy if exists order_items_admin    on order_items;
drop policy if exists stock_log_admin      on stock_log;

-- anyone may see the catalogue and its stock levels
create policy products_read_all on products
  for select using (true);

-- only a signed in admin may change prices, stock or availability
create policy products_write_admin on products
  for update to authenticated using (true) with check (true);

-- orders and their contents are readable only by a signed in admin.
-- customers never read them; they are written by place_order above.
create policy orders_admin on orders
  for all to authenticated using (true) with check (true);

create policy order_items_admin on order_items
  for all to authenticated using (true) with check (true);

create policy stock_log_admin on stock_log
  for all to authenticated using (true) with check (true);
