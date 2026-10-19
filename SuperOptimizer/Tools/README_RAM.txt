SUPER OPTIMIZER - RAM CLEANER
=============================

A partir da V3.4.3, as funções de RAM NÃO dependem de EmptyStandbyList.exe.

Método padrão:
- API nativa do Windows via NtSetSystemInformation / SystemMemoryListInformation
- privilégio SeProfileSingleProcessPrivilege habilitado no processo elevado

Comandos usados manualmente:
- Standby RAM: MemoryPurgeStandbyList
- Limpeza completa: MemoryEmptyWorkingSets + MemoryFlushModifiedList + MemoryPurgeStandbyList

EmptyStandbyList.exe:
- é totalmente OPCIONAL
- se colocado nesta pasta, serve apenas como fallback se o método nativo falhar
- antes de executar, o Super Optimizer valida cabeçalho PE, SHA-256 e Authenticode

Nenhuma limpeza de RAM roda automaticamente em perfis ou na Manutenção Semanal.
