-- Executar primeiro em ambiente de teste. Preserva dados existentes.
begin;
alter table public.profiles add column if not exists somente_almox boolean not null default false;
alter table public.remessas add column if not exists almox_origem uuid references public.almoxarifados(id), add column if not exists almox_destino uuid references public.almoxarifados(id);
create or replace function geox_private.rev08_restrito() returns boolean language sql stable security definer set search_path='' as $$ select coalesce((select somente_almox from public.profiles where id=auth.uid() and active),false) $$;
revoke all on function geox_private.rev08_restrito() from public; grant execute on function geox_private.rev08_restrito() to authenticated;
-- Restrição adicional: não altera permissões existentes dos demais usuários.
do $$ declare t text; begin foreach t in array array['remessas','itens_remessa','ordens_servico','equipamentos','manutencoes','operacoes_caminhao','movimentacoes_estoque'] loop execute format('drop policy if exists rev08_restrito on public.%I',t); execute format('create policy rev08_restrito on public.%I as restrictive for all to authenticated using (not geox_private.rev08_restrito()) with check (not geox_private.rev08_restrito())',t); end loop; end $$;
-- Impede alterações diretas em remessas integradas (RPC executa como proprietário).
create or replace function geox_private.rev08_guard_remessa() returns trigger language plpgsql set search_path='' as $$ begin if current_user in ('authenticated','anon') then if TG_OP='INSERT' then if new.almox_origem is not null or new.almox_destino is not null then raise exception 'Use a remessa integrada'; end if; elsif old.almox_origem is not null then raise exception 'Use as ações da remessa integrada'; elsif TG_OP='UPDATE' then if new.almox_origem is not null or new.almox_destino is not null then raise exception 'Use a remessa integrada'; end if; end if; end if; if TG_OP='DELETE' then return old; end if; return new; end $$;
drop trigger if exists rev08_guard_remessa on public.remessas;
create trigger rev08_guard_remessa before insert or update or delete on public.remessas for each row execute function geox_private.rev08_guard_remessa();
create or replace function geox_private.rev08_guard_item() returns trigger language plpgsql set search_path='' as $$ begin if current_user in ('authenticated','anon') then if TG_OP<>'INSERT' then if exists(select 1 from public.remessas where id=old.remessa_id and almox_origem is not null) then raise exception 'Item integrado protegido'; end if; end if; if TG_OP<>'DELETE' then if exists(select 1 from public.remessas where id=new.remessa_id and almox_origem is not null) then raise exception 'Item integrado protegido'; end if; end if; end if; if TG_OP='DELETE' then return old; end if; return new; end $$;
drop trigger if exists rev08_guard_item on public.itens_remessa;
create trigger rev08_guard_item before insert or update or delete on public.itens_remessa for each row execute function geox_private.rev08_guard_item();
-- Reserva lógica: qualquer baixa, inclusive consumo, respeita remessas em trânsito.
create or replace function geox_private.rev08_reserva() returns trigger language plpgsql security definer set search_path='' as $$ declare reservado numeric; begin select coalesce(sum(i.quantidade),0) into reservado from public.itens_remessa i join public.remessas r on r.id=i.remessa_id where r.almox_origem=old.almoxarifado_id and i.material_id=old.material_id and r.status='em_transito'; if new.saldo<reservado then raise exception 'Saldo reservado para remessas em trânsito: %',reservado; end if; return new; end $$;
drop trigger if exists rev08_reserva on public.estoque_almoxarifado;
create trigger rev08_reserva before update of saldo on public.estoque_almoxarifado for each row execute function geox_private.rev08_reserva();
create or replace function public.rev08_criar(p_origem uuid,p_destino uuid,p_motorista text,p_placa text,p_obs text,p_itens jsonb) returns uuid language plpgsql security definer set search_path='' as $$ declare rid uuid; x record; a public.almoxarifados%rowtype; b public.almoxarifados%rowtype; saldo numeric; reservado numeric; begin
if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active and role in ('admin','encarregado','operador') and not somente_almox) then raise exception 'Sem autorização logística'; end if;
if p_origem is null or p_destino is null or p_origem=p_destino or not geox_private.gx06_tem_acesso(p_origem,true) or not geox_private.gx06_tem_acesso(p_destino,true) then raise exception 'Origem/destino inválidos ou sem acesso'; end if;
select * into a from public.almoxarifados where id=p_origem and ativo; select * into b from public.almoxarifados where id=p_destino and ativo; if a.id is null or b.id is null then raise exception 'Almoxarifado inválido'; end if;
if jsonb_typeof(p_itens) is distinct from 'array' or coalesce(jsonb_array_length(p_itens),0)=0 then raise exception 'Selecione materiais'; end if;
if exists(select 1 from jsonb_to_recordset(p_itens) as j(material_id uuid,quantidade numeric) where material_id is null or quantidade is null or quantidade<=0 or quantidade>100000000) then raise exception 'Quantidade inválida'; end if;
for x in select material_id,sum(quantidade) qtd from jsonb_to_recordset(p_itens) as j(material_id uuid,quantidade numeric) group by material_id order by material_id loop
select e.saldo into saldo from public.estoque_almoxarifado e where e.almoxarifado_id=p_origem and e.material_id=x.material_id for update;
select coalesce(sum(i.quantidade),0) into reservado from public.itens_remessa i join public.remessas r on r.id=i.remessa_id where r.almox_origem=p_origem and r.status='em_transito' and i.material_id=x.material_id;
if saldo is null or saldo-reservado<x.qtd then raise exception 'Saldo disponível insuficiente'; end if; end loop;
insert into public.remessas(origem,destino,obra_id,motorista,placa,status,data_saida,observacoes,created_by,almox_origem,almox_destino) values(a.nome,b.nome,b.obra_id,p_motorista,p_placa,'em_transito',now(),p_obs,auth.uid(),a.id,b.id) returning id into rid;
insert into public.itens_remessa(remessa_id,material_id,descricao,quantidade,unidade) select rid,m.id,m.descricao,sum(j.quantidade),m.unidade from jsonb_to_recordset(p_itens) as j(material_id uuid,quantidade numeric) join public.materiais m on m.id=j.material_id group by m.id,m.descricao,m.unidade; return rid; end $$;
create or replace function public.rev08_finalizar(p_id uuid,p_cancelar boolean default false) returns void language plpgsql security definer set search_path='' as $$ declare r public.remessas%rowtype; x record; begin
if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and active and role in ('admin','encarregado','operador') and not somente_almox) then raise exception 'Sem autorização logística'; end if;
select * into r from public.remessas where id=p_id for update; if r.almox_origem is null or r.almox_destino is null then raise exception 'Remessa não integrada'; end if;
if not geox_private.gx06_tem_acesso(r.almox_origem,true) or not geox_private.gx06_tem_acesso(r.almox_destino,true) then raise exception 'Sem acesso'; end if;
if r.status<>'em_transito' then raise exception 'Remessa já finalizada'; end if;
-- Bloqueia estoque antes de liberar reserva, na mesma transação.
perform 1 from public.estoque_almoxarifado e where e.almoxarifado_id in (r.almox_origem,r.almox_destino) and e.material_id in (select material_id from public.itens_remessa where remessa_id=p_id) order by e.material_id,e.almoxarifado_id for update;
update public.remessas set status=case when p_cancelar then 'cancelada' else 'recebida' end,data_recebimento=case when p_cancelar then null else now() end where id=p_id;
if not p_cancelar then for x in select material_id,quantidade from public.itens_remessa where remessa_id=p_id order by material_id loop perform public.gx06_movimentar('transferencia',x.material_id,x.quantidade,r.almox_origem,r.almox_destino,null,'Remessa '||r.numero::text); end loop; end if; end $$;
revoke all on function public.rev08_criar(uuid,uuid,text,text,text,jsonb),public.rev08_finalizar(uuid,boolean) from public,anon;
grant execute on function public.rev08_criar(uuid,uuid,text,text,text,jsonb),public.rev08_finalizar(uuid,boolean) to authenticated;
-- Consulta nunca movimenta, mesmo se receber permissão individual por engano.
create or replace function geox_private.gx06_tem_acesso(p_alm uuid,p_editar boolean default false) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and (not p_editar or p.role in ('admin','encarregado','operador')) and (p.role='admin' or exists(select 1 from public.acessos_almoxarifado ac where ac.user_id=p.id and ac.almoxarifado_id=p_alm and (not p_editar or ac.pode_movimentar)))) $$;
commit;
