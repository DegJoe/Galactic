-- SaleSpark schema v1 (Supabase / PostgreSQL). STATUS: written, NOT yet executed against a database.
-- Money = integer pesewas. Run in Supabase SQL editor, then create the 2 users in Auth and insert their profiles.
create table profiles (id uuid primary key references auth.users on delete cascade,
  full_name text not null, role text not null check (role in ('owner','admin')));
create table products (id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name))>0), price_p int not null check (price_p>=0),
  stock numeric(12,2) not null default 0 check (stock>=0), low_level numeric(12,2) not null default 5,
  active boolean not null default true, created_at timestamptz default now());
create table customers (id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name))>0), phone text, created_at timestamptz default now());
create table sales (id uuid primary key default gen_random_uuid(), idem_key uuid not null unique,
  receipt_no bigint generated always as identity, customer_id uuid references customers,
  sold_on date not null default current_date, total_p int not null check (total_p>=0),
  change_p int not null default 0 check (change_p>=0), created_by uuid default auth.uid(), created_at timestamptz default now());
create table sale_items (id uuid primary key default gen_random_uuid(), sale_id uuid not null references sales on delete cascade,
  product_id uuid not null references products, qty numeric(12,2) not null check (qty>0), unit_price_p int not null check (unit_price_p>=0));
-- Only money that stays in the business. Change is never stored here, so it can never become revenue.
create table payments (id uuid primary key default gen_random_uuid(), sale_id uuid not null references sales,
  customer_id uuid references customers, method text not null check (method in ('cash','momo')),
  amount_p int not null check (amount_p>0), kind text not null check (kind in ('sale','repayment')),
  paid_on date not null default current_date, created_by uuid default auth.uid(), created_at timestamptz default now());
create table stock_movements (id uuid primary key default gen_random_uuid(), product_id uuid not null references products,
  qty_change numeric(12,2) not null, reason text not null check (reason in ('opening','sale','restock','adjustment')),
  cost_p int, ref_id uuid, created_by uuid default auth.uid(), created_at timestamptz default now());

create view sale_balances as select s.id sale_id, s.customer_id, s.sold_on, s.total_p,
  s.total_p - coalesce(sum(p.amount_p),0)::int as balance_p
  from sales s left join payments p on p.sale_id=s.id group by s.id;

create function is_member() returns boolean language sql stable security definer set search_path=public
  as $$ select exists(select 1 from profiles where id=auth.uid()) $$;
create function is_admin() returns boolean language sql stable security definer set search_path=public
  as $$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;

do $$ declare t text; begin
  foreach t in array array['profiles','products','customers','sales','sale_items','payments','stock_movements'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "members read" on %I for select using (is_member())', t);
  end loop; end $$;
-- Writes to sales/payments/stock go ONLY through the functions below (no insert policies = direct inserts denied).
create policy "admin writes products" on products for all using (is_admin()) with check (is_admin());
create policy "members add customers" on customers for insert with check (is_member());
create policy "admin edits customers" on customers for update using (is_admin());
alter view sale_balances set (security_invoker = true);

create function record_sale(p_idem uuid, p_customer uuid, p_date date, p_items jsonb, p_cash int, p_momo int)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_total int := 0; v_applied int; v_item jsonb; v_prod products; v_qty numeric; begin
  if not is_member() then raise exception 'not authorised'; end if;
  select id into v_id from sales where idem_key=p_idem;          -- duplicate submit/retry: return original
  if found then return v_id; end if;
  if p_cash<0 or p_momo<0 then raise exception 'negative payment'; end if;
  insert into sales(idem_key,customer_id,sold_on,total_p) values (p_idem,p_customer,coalesce(p_date,current_date),0) returning id into v_id;
  for v_item in select * from jsonb_array_elements(p_items) order by (value->>'product_id') loop   -- fixed lock order avoids deadlocks
    v_qty := (v_item->>'qty')::numeric;
    select * into v_prod from products where id=(v_item->>'product_id')::uuid and active for update;
    if not found then raise exception 'unknown product'; end if;
    if v_qty<=0 or v_prod.stock<v_qty then raise exception 'insufficient stock for %', v_prod.name; end if;
    update products set stock=stock-v_qty where id=v_prod.id;
    insert into sale_items(sale_id,product_id,qty,unit_price_p) values (v_id,v_prod.id,v_qty,v_prod.price_p);
    insert into stock_movements(product_id,qty_change,reason,ref_id) values (v_prod.id,-v_qty,'sale',v_id);
    v_total := v_total + round(v_qty*v_prod.price_p)::int;
  end loop;
  if p_momo>v_total then raise exception 'MoMo exceeds total'; end if;
  v_applied := least(p_cash, v_total-p_momo);
  if v_total-p_momo-v_applied>0 and p_customer is null then raise exception 'credit sale needs a customer'; end if;
  update sales set total_p=v_total, change_p=p_cash-v_applied where id=v_id;
  if v_applied>0 then insert into payments(sale_id,customer_id,method,amount_p,kind,paid_on) values (v_id,p_customer,'cash',v_applied,'sale',coalesce(p_date,current_date)); end if;
  if p_momo>0 then insert into payments(sale_id,customer_id,method,amount_p,kind,paid_on) values (v_id,p_customer,'momo',p_momo,'sale',coalesce(p_date,current_date)); end if;
  return v_id; end $$;

create function record_repayment(p_customer uuid, p_method text, p_amount int, p_date date) returns void
language plpgsql security definer set search_path=public as $$
declare r record; v_left int := p_amount; v_take int; v_owed int; begin
  if not is_member() then raise exception 'not authorised'; end if;
  if p_amount<=0 or p_method not in ('cash','momo') then raise exception 'invalid repayment'; end if;
  perform 1 from customers where id=p_customer for update;      -- serialises concurrent repayments for one customer
  select coalesce(sum(balance_p),0) into v_owed from sale_balances where customer_id=p_customer and balance_p>0;
  if p_amount>v_owed then raise exception 'repayment exceeds outstanding balance'; end if;
  for r in select sale_id,balance_p from sale_balances where customer_id=p_customer and balance_p>0 order by sold_on,sale_id loop
    exit when v_left=0; v_take := least(v_left,r.balance_p);
    insert into payments(sale_id,customer_id,method,amount_p,kind,paid_on) values (r.sale_id,p_customer,p_method,v_take,'repayment',coalesce(p_date,current_date));
    v_left := v_left-v_take; end loop; end $$;

create function restock(p_product uuid, p_qty numeric, p_cost_p int) returns void
language plpgsql security definer set search_path=public as $$ begin
  if not is_member() or p_qty<=0 then raise exception 'invalid restock'; end if;
  update products set stock=stock+p_qty where id=p_product;
  insert into stock_movements(product_id,qty_change,reason,cost_p) values (p_product,p_qty,'restock',p_cost_p); end $$;
revoke all on function record_sale, record_repayment, restock from public; grant execute on function record_sale, record_repayment, restock to authenticated;
