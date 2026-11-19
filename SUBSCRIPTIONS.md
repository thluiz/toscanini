# Inscrições de feeds

Backup da configuração da tabela `feed_subscriptions`, reescrito automaticamente quando uma assinatura é criada, alterada ou removida. Não editar à mão: a próxima escrita sobrescreve.

Não inclui a marca do último episódio visto (`last_episode_uuid`, `last_published_at`, `last_checked_at`), que muda a cada checagem. Na restauração, cada assinatura ganha uma marca nova (o episódio mais recente do feed), sem reprocessar o catálogo.

Restaurar: `mix ecto.migrate` num banco vazio e depois `mix toscanini.restore_subscriptions` (opções `--file` e `--dry-run`).

| Título | source | feed_ref | active | auto_annotate | check_days | hot (min) | idle (min) |
|---|---|---|---|---|---|---|---|
| #Provocast | pocketcasts | `cca71c70-d321-0137-1e20-0acc26574db2` | sim | não | thu | 60 | 1440 |
| .NET Rocks! | pocketcasts | `2b369ce0-0426-012e-f9a0-00163e1b201c` | sim | não | wed,thu | 60 | 1440 |
| 80,000 Hours Podcast | pocketcasts | `99d6aaa0-2e41-0135-52f9-452518e2d253` | sim | não | tue,wed,thu | 60 | 1440 |
| AI News & Strategy Daily \| Nate B Jones | youtube | `UC0C-17n9iuUQPylguM1d-lQ` | sim | não | mon,tue,wed,thu,fri,sat,sun | 60 | 1440 |
| Anarchist Essays | pocketcasts | `308d9020-e266-0138-e7c9-0acc26574db2` | sim | não | mon | 60 | 1440 |
| Antinomia | pocketcasts | `890a4120-0306-0138-9f4f-0acc26574db2` | sim | não | nenhum | 60 | 1440 |
| Aqui a música toca. \| Osesp | pocketcasts | `f6492aa0-5205-013d-1965-0acc26574db2` | sim | não | tue | 60 | 1440 |
| Atila Iamarino | youtube | `UCSTlOTcyUmzvhQi6F8lFi5w` | sim | não | wed,fri | 60 | 1440 |
| Behind the Bastards | pocketcasts | `d9c015b0-255d-0136-c266-7d73a919276a` | sim | não | tue,thu,sat | 60 | 1440 |
| Better Offline | pocketcasts | `00cb7090-ac21-013c-a034-0acc26574db2` | sim | não | wed,fri | 60 | 1440 |
| Boa Noite Internet | pocketcasts | `bebaacf0-d567-0136-3249-08b04944ede4` | sim | não | sun | 60 | 1440 |
| Bom Dia, Fim do Mundo | pocketcasts | `541d0c90-42c7-013d-193e-0acc26574db2` | sim | não | thu | 60 | 1440 |
| Braincast | pocketcasts | `47e85350-420a-012f-069a-525400c11844` | sim | não | mon | 60 | 1440 |
| Calma Urgente | pocketcasts | `2a566eb0-ddce-013c-5d0d-0acc26574db2` | sim | sim | mon,tue | 60 | 1440 |
| Chutando a Escada | pocketcasts | `0bdfc250-55b6-0134-ec37-0d50f522381b` | sim | não | thu | 60 | 1440 |
| Cinemático | pocketcasts | `6be6ad10-1938-0135-52f8-452518e2d253` | sim | não | tue,thu | 60 | 1440 |
| Clóvis de Barros | youtube | `UCPfEa4hhzVGOxt05mWKHvZQ` | sim | não | tue,wed,thu,fri,sun | 60 | 1440 |
| Computação Crítica por Victor Osório | youtube | `UC6g6eok10NJGYgenHO-0Oew` | sim | não | nenhum | 60 | 1440 |
| Crise Crise Crise | pocketcasts | `15f3f0a0-5023-013c-f72c-0acc26574db2` | sim | não | nenhum | 60 | 1440 |
| Desculpa o Transtorno | pocketcasts | `fb595340-17f7-013f-8f7c-0affcf9e76dd` | sim | não | mon | 60 | 1440 |
| Developer Tea | pocketcasts | `cbe9b6c0-7da4-0132-e6ef-5f4c86fd3263` | sim | não | wed,thu | 60 | 1440 |
| Duas e Tanto | pocketcasts | `bbba0d00-1c7f-013e-8aec-0e8fd7e33bcf` | sim | não | tue,thu | 60 | 1440 |
| Elefantes na Neblina | pocketcasts | `076b7250-7b38-0138-edfa-0acc26574db2` | sim | não | nenhum | 60 | 1440 |
| Elixir Wizards | pocketcasts | `722afb10-1b49-0137-f265-1d245fc5f9cf` | sim | não | thu | 60 | 1440 |
| Escafandro | pocketcasts | `ff036de0-0f90-0137-f265-1d245fc5f9cf` | sim | não | wed | 60 | 1440 |
| Fabio Akita | youtube | `UCib793mnUOhWymCh2VJKplQ` | sim | não | nenhum | 60 | 1440 |
| Falando de História | pocketcasts | `3907a740-0b7e-0139-41b2-0acc26574db2` | sim | não | mon | 60 | 1440 |
| Falando nIsso | pocketcasts | `d19dac70-4f6c-0139-3399-0acc26574db2` | sim | não | tue,fri | 60 | 1440 |
| Filosofia Pop | pocketcasts | `56aa96e0-d74d-0132-0356-059c869cc4eb` | sim | não | mon | 60 | 1440 |
| Filosofia Vermelha | pocketcasts | `dd38e8c0-673a-0138-a0de-0acc26574db2` | sim | não | mon | 60 | 1440 |
| Foro de Teresina | pocketcasts | `c30f72e0-3a5a-0136-fa7b-0fe84b59566d` | sim | não | fri | 60 | 1440 |
| Hanselminutes with Scott Hanselman | pocketcasts | `3532c690-01c7-0130-ad31-723c91aeae46` | sim | não | thu | 60 | 1440 |
| History of Philosophy Without Any Gaps | pocketcasts | `399753f0-0424-012e-f9a0-00163e1b201c` | sim | não | sun | 60 | 1440 |
| História Pirata | pocketcasts | `d65f6080-7f7b-0138-ee0e-0acc26574db2` | sim | não | sun,mon | 60 | 1440 |
| How to Be a Better Human | pocketcasts | `ec3a1f40-21ce-0139-32b5-0acc26574db2` | sim | não | mon | 60 | 1440 |
| Ilustríssima Conversa | pocketcasts | `0f544d90-22fc-0136-c266-7d73a919276a` | sim | não | sat | 60 | 1440 |
| Imposturas Filosóficas | pocketcasts | `5be51750-775a-0136-7b8e-27f978dac4db` | sim | não | fri | 60 | 1440 |
| Interesting Times with Ross Douthat | pocketcasts | `045f3aa0-aa6a-0136-7b93-27f978dac4db` | sim | não | thu | 60 | 1440 |
| Introvertendo - Autismo por Autistas | pocketcasts | `26c0a450-3cc1-0136-fa7b-0fe84b59566d` | sim | não | fri | 60 | 1440 |
| Isso não é uma sessão de análise, com Vera Iaconelli | pocketcasts | `e6d02e00-646b-013e-ba85-0acc26574db2` | sim | não | tue,thu | 60 | 1440 |
| Jornada da Odisseia | pocketcasts | `2b585cb0-bc20-013f-55d8-0affcb2f3ff3` | sim | não | nenhum | 60 | 1440 |
| José Kobori | youtube | `UCOKSOW5uJHdW7Edz37mvAFw` | sim | não | mon,tue,wed,thu,fri,sat,sun | 60 | 1440 |
| Kritikê Podcast | pocketcasts | `2daebee0-c8b7-0139-56b6-0acc26574db2` | sim | não | mon,tue,fri | 60 | 1440 |
| La Mezcla | pocketcasts | `90a5cdd0-e388-013e-f843-022038d1b2e1` | sim | não | mon | 60 | 1440 |
| Lado B do Rio | pocketcasts | `20e7d0d0-4d5c-0134-ec0b-0d50f522381b` | sim | não | tue | 60 | 1440 |
| Lambda3 Podcast | pocketcasts | `2c13caf0-f08d-0133-9c6b-59d98c6b72b8` | sim | não | fri | 60 | 1440 |
| Lenny's Podcast: Product \| Career \| Growth | pocketcasts | `aff3edd0-c8a4-013a-d954-0acc26574db2` | sim | não | sun | 60 | 1440 |
| Mamilos | pocketcasts | `8e5629f0-512e-0132-cf87-5f4c86fd3263` | sim | não | tue | 60 | 1440 |
| mano deyvin | youtube | `UC1VZDEtGNxfQzh7EYcD2frg` | sim | não | mon,tue,wed,thu,fri,sat,sun | 60 | 1440 |
| Matt Pocock | youtube | `UCswG6FSbgZjbWtdf_hMLaow` | sim | não | mon,wed,thu | 60 | 1440 |
| Medo e Delírio em Brasília | pocketcasts | `888d5760-4c1b-0138-9785-0acc26574db2` | sim | não | thu,sat | 60 | 1440 |
| MIDCast Política | pocketcasts | `459b62a0-ef36-0135-c25e-7d73a919276a` | sim | não | mon,sun | 60 | 1440 |
| Mitografias | pocketcasts | `46092170-50de-0136-fa7c-0fe84b59566d` | sim | não | thu | 60 | 1440 |
| Mo Bitar | youtube | `UCAwT-7B6StW_xzXPku6v7MQ` | sim | não | mon,tue,wed | 60 | 1440 |
| Modern CTO | pocketcasts | `509a1ca0-c507-0135-9e60-5bb073f92b78` | sim | não | mon,thu | 60 | 1440 |
| Naruhodo | pocketcasts | `3f602eb0-4ae0-0134-ebfa-0d50f522381b` | sim | não | mon | 60 | 1440 |
| NerdCast | pocketcasts | `7622ef30-3f20-0131-77d1-723c91aeae46` | sim | não | fri | 60 | 1440 |
| Noites Gregas | pocketcasts | `0e44cbe0-0874-0138-9f63-0acc26574db2` | sim | não | fri | 60 | 1440 |
| NORMOSE | youtube | `UCqBY-VQ2BxHOWnVpuC7swrw` | sim | não | nenhum | 60 | 1440 |
| Nosso Podcast de Cinema | pocketcasts | `76eb6ca0-9a1f-0139-c12b-0acc26574db2` | sim | não | thu | 60 | 1440 |
| O Assunto | pocketcasts | `9cc32e40-a9cb-0137-fae6-0acc26574db2` | sim | não | mon,tue,wed,thu,fri | 60 | 1440 |
| O Princípio da Inquietação | pocketcasts | `871a4f30-26e1-013f-2ec2-0e872f6a2b21` | sim | não | thu | 60 | 1440 |
| Olá, Gabs | pocketcasts | `733cbf80-c4fd-013b-f422-0acc26574db2` | sim | não | fri,sat | 60 | 1440 |
| Petit Journal | pocketcasts | `cafea300-b9d7-0134-10a8-25324e2a541d` | sim | não | mon,tue,wed,thu,fri | 60 | 1440 |
| Philosophy For Our Times | pocketcasts | `91d0f4a0-585b-0134-cf69-7b84bf375f4c` | sim | não | tue | 60 | 1440 |
| Pivot | pocketcasts | `6fd43fe0-9a3f-0133-2dbd-6dc413d6d41d` | sim | não | tue,fri | 60 | 1440 |
| Pivot to AI | pocketcasts | `240b29d0-084d-013e-0d67-0269e71698d3` | sim | não | mon,tue,wed,thu,fri | 60 | 1440 |
| Podcast MdM – Melhores do Mundo | pocketcasts | `1a2604f0-4c89-012f-0b3e-525400c11844` | sim | não | fri | 60 | 1440 |
| Podcast Tecnopolítica | pocketcasts | `103c3210-e6de-0136-3249-08b04944ede4` | sim | não | tue,wed,thu | 60 | 1440 |
| RapaduraCast - Podcast de Cinema e Streaming | pocketcasts | `08d366d0-296b-012e-07b0-00163e1b201c` | sim | não | fri,sat | 60 | 1440 |
| REWORK | pocketcasts | `d8d4ae20-58e7-0135-902c-63f4b61a9224` | sim | não | wed | 60 | 1440 |
| Rádio Companhia | pocketcasts | `42739080-7f41-0134-904b-3327a14bcdba` | sim | não | wed | 60 | 1440 |
| Scott & Mark Learn To... | pocketcasts | `ef796ea0-6892-013d-aba9-0affd8d03709` | sim | não | wed | 60 | 1440 |
| Silicon Valley Girl: AI, Tech and Career Growth | pocketcasts | `d3ebe030-29f4-013e-1bdc-0acc26574db2` | sim | não | tue,fri | 60 | 1440 |
| Tech Lead Journal | pocketcasts | `952099f0-a7bc-0138-e686-0acc26574db2` | sim | não | mon | 60 | 1440 |
| Tecnologia e Classe (TeClas) | youtube | `UCYVrkMZdrjq5eICOG6Rxiwg` | sim | não | mon,tue,wed,thu,fri | 60 | 1440 |
| The Bike Shed | pocketcasts | `ce1490c0-4406-0132-c909-5f4c86fd3263` | sim | não | tue | 60 | 1440 |
| The Ezra Klein Show | pocketcasts | `8535a4e0-3c50-0139-3339-0acc26574db2` | sim | não | tue,wed | 60 | 1440 |
| The Gray Area with Sean Illing | pocketcasts | `1d3ce9a0-ae3d-0133-2e33-6dc413d6d41d` | sim | não | mon,fri | 60 | 1440 |
| The Pragmatic Engineer | pocketcasts | `59045350-573e-013d-e880-02cacb2c6223` | sim | não | wed | 60 | 1440 |
| The Productivity Show | pocketcasts | `e9a4aa60-7486-0132-e1d6-5f4c86fd3263` | sim | não | mon,wed | 60 | 1440 |
| The Stack Overflow Podcast | pocketcasts | `2c22bfa0-cecf-0130-37a2-723c91aeae46` | sim | não | tue,fri | 60 | 1440 |
| The Tech Report | pocketcasts | `48f7dbe0-f123-013e-8105-0afffacbab17` | sim | não | mon,wed,thu | 60 | 1440 |
| Theo - t3․gg | youtube | `UCbRP3c757lWg9M-U7TyEkXA` | sim | não | mon,tue,wed,thu,fri | 60 | 1440 |
| Think Fast Talk Smart: Communication Techniques | pocketcasts | `801704e0-1ee9-0138-9fc1-0acc26574db2` | sim | não | mon,thu | 60 | 1440 |
| Uma Tupá no Tempo | pocketcasts | `d0517fe0-8860-013e-59fd-0affef269edf` | sim | não | mon,sat | 60 | 1440 |
| Unexplainable | pocketcasts | `e7f5ba60-584b-0139-33c5-0acc26574db2` | sim | não | mon,wed | 60 | 1440 |
| Viracasacas | pocketcasts | `dee3a250-f2f5-0134-ec5e-4114446340cb` | sim | sim | tue,fri | 60 | 1440 |
| Xadrez Verbal | pocketcasts | `b9b05d90-d8cc-0132-0349-059c869cc4eb` | sim | não | thu,fri,sat | 60 | 1440 |
| É sobre isso | pocketcasts | `ef647b60-bcb9-013d-c741-0affcf0896e5` | sim | não | tue,wed | 60 | 1440 |
| É tudo culpa da cultura | pocketcasts | `d90ebe80-43bf-013c-f6ea-0acc26574db2` | sim | não | tue | 60 | 1440 |
