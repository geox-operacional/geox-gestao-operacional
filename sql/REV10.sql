begin;
-- Atualização incremental, sem reiniciar estoque.
 alter table public.remessas add column if not exists arquivada boolean not null default false;
create or replace function public.rev10_material(p_dados jsonb,p_id uuid,p_alm uuid,p_qtd numeric) returns uuid language plpgsql security definer set search_path='' as $$
declare mid uuid; r text; c numeric; begin
select role into r from public.profiles where id=auth.uid() and active;
if r is null or r not in ('admin','encarregado','operador') then raise exception 'Sem autorização'; end if;
if p_qtd is null or p_qtd<0 or p_qtd>100000000 or (p_qtd>0 and p_alm is null) then raise exception 'Quantidade ou obra inválida'; end if;
if p_alm is not null and not geox_private.gx06_tem_acesso(p_alm,true) then raise exception 'Sem acesso à obra'; end if;
if p_id is null then
insert into public.materiais(codigo,descricao,unidade,categoria,custo_unitario,estoque_minimo,saldo,fornecedor,localizacao) values(p_dados->>'codigo',p_dados->>'descricao',p_dados->>'unidade',p_dados->>'categoria',case when r='admin' then coalesce((p_dados->>'custo_unitario')::numeric,0) else 0 end,coalesce((p_dados->>'estoque_minimo')::numeric,0),0,p_dados->>'fornecedor',p_dados->>'localizacao') returning id into mid;
else mid:=p_id; if r='admin' and p_dados is not null then update public.materiais set descricao=p_dados->>'descricao',categoria=p_dados->>'categoria',fornecedor=p_dados->>'fornecedor',localizacao=p_dados->>'localizacao' where id=mid; end if; end if;
if p_qtd>0 then perform public.gx06_movimentar('entrada',mid,p_qtd,null,p_alm,null,'Cadastro/alocação REV10'); end if; return mid; end $$;
create or replace function public.rev10_remessa(p_id uuid,p_acao text,p_motorista text default null,p_placa text default null,p_obs text default null) returns void language plpgsql security definer set search_path='' as $$
declare r public.remessas%rowtype; perfil text; x record; begin
select role into perfil from public.profiles where id=auth.uid() and active and not somente_almox;
if perfil is null or perfil not in ('admin','encarregado','operador') then raise exception 'Sem autorização'; end if;
select * into r from public.remessas where id=p_id for update;
if not found or r.arquivada or r.almox_origem is null then raise exception 'Remessa inválida'; end if;
if not geox_private.gx06_tem_acesso(r.almox_origem,true) or not geox_private.gx06_tem_acesso(r.almox_destino,true) then raise exception 'Sem acesso'; end if;
if p_acao='editar' then update public.remessas set motorista=p_motorista,placa=p_placa,observacoes=p_obs where id=p_id;
elsif p_acao='excluir' and perfil='admin' then
if r.status='recebida' then raise exception 'Remessa recebida: estorne antes de excluir'; end if;
if r.status='em_transito' then perform public.rev08_finalizar(p_id,true); end if;
update public.remessas set arquivada=true where id=p_id;
elsif p_acao='estornar' and perfil='admin' and r.status='recebida' then
for x in select material_id,sum(quantidade) quantidade from public.itens_remessa where remessa_id=p_id group by material_id order by material_id loop perform public.gx06_movimentar('transferencia',x.material_id,x.quantidade,r.almox_destino,r.almox_origem,null,'Estorno remessa '||r.numero::text); end loop;
update public.remessas set status='cancelada',observacoes=concat_ws(' | ',observacoes,'Estornada REV10') where id=p_id;
else raise exception 'Ação não permitida'; end if; end $$;
revoke all on function public.rev10_material(jsonb,uuid,uuid,numeric),public.rev10_remessa(uuid,text,text,text,text) from public,anon;
grant execute on function public.rev10_material(jsonb,uuid,uuid,numeric),public.rev10_remessa(uuid,text,text,text,text) to authenticated;
commit;
