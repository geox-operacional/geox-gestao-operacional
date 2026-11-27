begin;
-- Cria almoxarifado automaticamente para novas obras; mantém o vínculo por UUID.
create or replace function geox_private.rev09_obra_almox() returns trigger language plpgsql security definer set search_path='' as $$ begin
if TG_OP='INSERT' then insert into public.almoxarifados(nome,obra_id,ativo) values(new.nome,new.id,true); else update public.almoxarifados set nome=new.nome where obra_id=new.id and nome=old.nome; end if; return new; end $$;
drop trigger if exists rev09_obra_almox on public.obras;
create trigger rev09_obra_almox after insert or update of nome on public.obras for each row execute function geox_private.rev09_obra_almox();
commit;
