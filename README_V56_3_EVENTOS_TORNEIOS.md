# Q-Rival V56.3 — Eventos e Torneios do servidor

Esta atualização adiciona ao Painel Administrativo atalhos separados para **Eventos** e **Torneios**.

## Eventos
- Criar/publicar evento com nome, descrição, categoria, início e fim.
- Selecionar condição automática:
  - vitórias consecutivas;
  - vitórias com pontuação mínima;
  - vitórias consecutivas + categoria + pontuação mínima.
- Escolher quantidade de vitórias e pontuação mínima.
- Selecionar item da Loja como recompensa de conclusão.
- Evento pode ser ativado/inativado, editado e excluído.
- Ao publicar, todos os jogadores recebem uma notificação.
- A recompensa de item é entregue uma única vez quando a meta é concluída.

## Torneios
- Criar/publicar torneio com categoria, datas, status, limite de jogadores e entrada em Coins.
- Definir prêmio em XP, Coins e item da Loja.
- Editar, encerrar e excluir torneios pelo painel.
- Ao publicar, todos os jogadores recebem uma notificação.

## Banco de dados
Execute o arquivo `SUPABASE_QRIVAL_UNICO.sql` no SQL Editor do Supabase. Ele contém a estrutura de progresso automático dos eventos e a notificação global dos torneios.
