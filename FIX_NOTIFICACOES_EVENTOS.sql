-- Q-Rival v56.3 — correção do erro ao publicar Eventos
-- Execute este bloco no Supabase se o banco já estiver atualizado e
-- você não quiser rodar o SQL completo novamente.

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check
check (type in ('system','challenge','friend_request','message','like','comment','achievement','coin','event'));

