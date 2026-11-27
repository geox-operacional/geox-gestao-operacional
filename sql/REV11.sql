begin;
create table if not exists public.abastecimentos(id uuid primary key default gen_random_uuid(), obra_id uuid not null references public.obras(id), data_abastecimento date not null, veiculo text not null, responsavel text not null, combustivel text not null, litros numeric not null check(litros>0), valor_unitario numeric not null default 0 check(valor_unitario>=0), km_horimetro numeric check(km_horimetro>=0), observacoes text, created_at timestamptz default now());
alter table public.abastecimentos enable row level security;
grant select,insert,update,delete on public.abastecimentos to authenticated;
drop policy if exists rev11_read on public.abastecimentos;
create policy rev11_read on public.abastecimentos for select to authenticated using ((select geox_private.current_role()) in ('admin','encarregado','operador','consulta') and not geox_private.rev08_restrito());
drop policy if exists rev11_write on public.abastecimentos;
create policy rev11_write on public.abastecimentos for all to authenticated using ((select geox_private.current_role()) in ('admin','encarregado','operador') and not geox_private.rev08_restrito()) with check ((select geox_private.current_role()) in ('admin','encarregado','operador') and not geox_private.rev08_restrito());
-- Preserve original ID; reverse old transfer and reserve/transfer replacement atomically.
create or replace function public.rev11_editar(p_id uuid,p_origem uuid,p_destino uuid,p_motorista text,p_placa text,p_obs text,p_itens jsonb,p_status text,p_saida timestamptz,p_recebimento timestamptz) returns void language plpgsql security definer set search_path='' as $$
declare r public.remessas%rowtype; n uuid; perfil text; x record; begin
select role into perfil from public.profiles where id=auth.uid() and active and not somente_almox;
if perfil is null or perfil not in ('admin','encarregado','operador') then raise exception 'Sem autorização'; end if;
select * into r from public.remessas where id=p_id for update;
if not found or r.arquivada or r.almox_origem is null then raise exception 'Remessa inválida'; end if;
if r.status='recebida' and perfil<>'admin' then raise exception 'Somente administrador altera remessa concluída'; end if;
if p_status is null or p_status not in ('em_transito','recebida','cancelada','pendente') or p_saida is null or (p_status='recebida' and p_recebimento is not null and p_recebimento<p_saida) then raise exception 'Status ou data inválida'; end if;
if not geox_private.gx06_tem_acesso(r.almox_origem,true) or not geox_private.gx06_tem_acesso(r.almox_destino,true) then raise exception 'Sem acesso'; end if;
if r.status='recebida' then perform public.rev10_remessa(p_id,'estornar'); elsif r.status='em_transito' then perform public.rev08_finalizar(p_id,true); end if;
n:=public.rev08_criar(p_origem,p_destino,p_motorista,p_placa,p_obs,p_itens);
-- Remove temporary reservation before moving its items to original ID.
update public.remessas set status='cancelada' where id=n;
delete from public.itens_remessa where remessa_id=p_id;
update public.itens_remessa set remessa_id=p_id where remessa_id=n;
update public.remessas set almox_origem=p_origem,almox_destino=p_destino,origem=(select nome from public.almoxarifados where id=p_origem),destino=(select nome from public.almoxarifados where id=p_destino),obra_id=(select obra_id from public.almoxarifados where id=p_destino),motorista=p_motorista,placa=p_placa,observacoes=p_obs,data_saida=p_saida,data_recebimento=null,status='em_transito' where id=p_id;
delete from public.remessas where id=n;
if p_status='recebida' then perform public.rev08_finalizar(p_id,false); update public.remessas set data_recebimento=coalesce(p_recebimento,now()) where id=p_id; elsif p_status<>'em_transito' then perform public.rev08_finalizar(p_id,true); update public.remessas set status=p_status where id=p_id; end if;
end $$;
revoke all on function public.rev11_editar(uuid,uuid,uuid,text,text,text,jsonb,text,timestamptz,timestamptz) from public,anon;
grant execute on function public.rev11_editar(uuid,uuid,uuid,text,text,text,jsonb,text,timestamptz,timestamptz) to authenticated;
-- Block legacy edit route for non-admin completed shipments.
create or replace function geox_private.rev11_concluida() returns trigger language plpgsql set search_path='' as $$ begin if old.status='recebida' and auth.uid() is not null and not exists(select 1 from public.profiles where id=auth.uid() and active and role='admin') then raise exception 'Somente administrador altera remessa concluída'; end if; if TG_OP='DELETE' then return old; end if; return new; end $$;
drop trigger if exists rev11_concluida on public.remessas;
create trigger rev11_concluida before update or delete on public.remessas for each row execute function geox_private.rev11_concluida();
commit;
