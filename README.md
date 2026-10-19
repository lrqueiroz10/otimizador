# Super Optimizer — 3.9.0 DEV

Versão de desenvolvimento baseada na V3.8.1 FINAL enviada pelo usuário.
Os sete hashes da base foram verificados. Engine e Worker permanecem byte a byte
iguais aos originais. A referência completa foi preservada fora do projeto.

## Melhorias

- Comparador Antes → Depois em tabela, busca literal e exportação CSV filtrada.
- Valores ausentes, vazios, booleanos, arrays e objetos são exibidos explicitamente.
- Cancelamentos e operações bloqueadas não reutilizam resultados antigos.
- Auto-Teste exige relatório final válido, contagem positiva, todos os testes
  aprovados, ausência de erros e ExitCode zero. Falta de evidência é inconclusiva.
- Auto-Teste oculto continua monitorado, bloqueia operações concorrentes e mantém
  o limite de 180 segundos.
- Oito cenários de classificação são executados pelo próprio SelfTest.

## Uso e atualização

Requer Windows 11 e Windows PowerShell 5.1/WPF. Extraia a distribuição inteira e
abra `SuperOptimizer.bat`. `DIAGNOSTICO_INICIALIZACAO.bat` mostra erros de abertura.
Ao atualizar uma instalação existente, **preserve a pasta State** para manter
ORIGINAL, backups, histórico e rollback.

O ZIP não inclui o State pessoal do anexo nem o executável opcional DNS Jumper.
Sua instalação opcional é descrita em `SuperOptimizer/Tools/README_DNS_JUMPER.txt`.

## Verificação

Na raiz do projeto, execute:

```powershell
powershell.exe -NoLogo -NoProfile -File .\tests\UiRegression.Tests.ps1
powershell.exe -NoLogo -NoProfile -File .\tests\Integration.Tests.ps1
```

As suítes também funcionam com `pwsh`. Foram verificados em PowerShell 7.4.20/Linux
51 cenários de regressão e 50 verificações de integração, incluindo integridade
7/7, parser, versões, XML, comparador real do Engine, JSON e histórico temporário.
Os testes usam dados sintéticos e não chamam APIs de otimização do Windows.

A inicialização WPF, o Auto-Teste completo, Worker/IPC em processo separado,
aplicação real de perfis, System Restore e rollback ainda exigem validação em
Windows 11/PowerShell 5.1. Esta é uma DEV, não uma nova FINAL.

Na validação Windows, confira abertura real, Auto-Teste, busca/CSV no comparador,
cancelamento sem resultado antigo, bloqueio durante Auto-Teste oculto e liberação
após concluir. O State existente deve ser mantido.
