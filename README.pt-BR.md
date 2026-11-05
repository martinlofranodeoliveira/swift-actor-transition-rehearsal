# Actor Transition Rehearsal

**Versão de desenvolvimento 0.1.0.** Laboratório Swift sem interface gráfica, original da [Lofrano Tecnologia](https://lofranotecnologia.com.br). Actors reais suspendem em barreiras controladas. Snapshots imutáveis explicam admissão, reentrância, cancelamento e confirmação terminal. É uma ferramenta didática e de regressão, não um executor genérico nem uma fronteira de isolamento para produção.

Repositório: https://github.com/martinlofranodeoliveira/swift-actor-transition-rehearsal

## Ambiente e instalação

Ambiente selecionado: Linux x86_64, **Swift 6.2.4**, modo Swift 6, imagem oficial imutável registrada em `environment.json`. Não há pacotes Swift externos, serviços remotos, modelo, telemetria ou dependência de rede em execução. Os scripts de compilação/empacotamento também precisam da biblioteca padrão do Python 3 e de contêiner Linux com cgroup v2. Os arquivos de distribuição não incluem o compilador nem o runtime.

Separe obtenção de artefatos oficiais da execução offline:

```sh
docker pull swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855
docker build --network=none --pull=false --tag atr-qualified:0.1.0 - < Dockerfile
```

Abra o ambiente offline montando somente este diretório de fontes. Docker pertence ao executor externo confiável, não fica disponível dentro do contêiner:

```sh
docker run --rm -it --pull=never --network=none --cap-drop=ALL \
  --security-opt=no-new-privileges --user=1000:1000 \
  --memory=1g --memory-swap=1g --cpus=2 --pids-limit=256 \
  --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=805306368,uid=1000,gid=1000 \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  atr-qualified:0.1.0 /bin/sh
```

Dentro dele:

```sh
/bin/sh scripts/test-offline.sh
/bin/sh scripts/demo-offline.sh --assert
/bin/sh scripts/package.sh
```

O teste cria um pacote a partir de manifesto explícito, extrai fora do checkout, testa essas fontes, compila o CLI em release, instala seu arquivo em outro diretório novo, executa as duas línguas, compara relatórios canônicos e compila/executa um consumidor SwiftPM independente. Toda compilação Swift usa `--disable-sandbox --jobs 2 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`. O CLI instalado não precisa de Python.

O empacotamento grava distribuições reais e seus SHA-256 calculados em `/tmp/atr-artifacts`:

- `actor-transition-rehearsal-source-0.1.0.tar`: fontes originais, testes, scripts e documentação;
- `actor-transition-rehearsal-cli-0.1.0.tar`: `bin/actor-transition-rehearsal`, licença MIT, READMEs bilíngues, ambiente e avisos de projeto/licenças. Exige o runtime selecionado, sem incluí-lo.

Instalação no mesmo ambiente selecionado:

```sh
mkdir -p /tmp/atr-manual-install
tar -xf /tmp/atr-artifacts/actor-transition-rehearsal-cli-0.1.0.tar -C /tmp/atr-manual-install
cd /tmp/atr-manual-install
./bin/actor-transition-rehearsal --assert
./bin/actor-transition-rehearsal --assert --language pt-BR
./bin/actor-transition-rehearsal --assert --json
```

Os artefatos em `/tmp` duram somente durante a vida desse contêiner. O gate automatizado faz sua própria instalação independente. Não há comandos de publicação ou implantação.

## Demonstração

O CLI instalado, com `--assert --language pt-BR`, produz exatamente:

```text
Actor Transition Rehearsal 0.1.0 (desenvolvimento)
OK stale: stale; reservas=0
OK capacity: committed,cancelled; reservas=0
OK pre-cancel-task: cancelled; reservas=0
OK suspended-cancel-task: cancelled; reservas=0
OK resumed-cancel-task: cancelled; reservas=0
OK application-cancel: cancelled; reservas=0
OK commit-then-cancel: committed; reservas=0
OK snapshot: committed; reservas=0
```

Os identificadores e outcomes são estáveis nas duas línguas. `--json` emite um relatório JSON canônico com versão e oito snapshots, seguido de LF. Operações ficam ordenadas por identificador ASCII; eventos, por sequência lógica; chaves, lexicamente. Não entram relógios, UUIDs nem caminhos locais. Todos os cenários verificam resultados mesmo sem `--assert`; a opção explicita a intenção. Argumentos inválidos, opções desconhecidas/repetidas, falha de verificação e erros de E/S terminam com código 1 e erro limitado. Sucesso retorna 0. O CLI não lê stdin nem arquivos de entrada.

## Exemplo de biblioteca

Use as fontes extraídas como dependência SwiftPM **local**:

```swift
.package(path: "../actor-transition-rehearsal")
```

Adicione `.product(name: "ActorTransitionRehearsal", package: "actor-transition-rehearsal")` ao alvo consumidor. Função assíncrona completa que evidencia premissas invalidadas:

```swift
import ActorTransitionRehearsal

func exemploObsoleto() async throws -> Receipt {
    let ledger = Rehearsal(limits: try Limits(capacity: 1))
    let token = try await ledger.admit("amostra")
    let task = Task { try await ledger.execute(token) }
    do {
        _ = try await token.registration()
        _ = try await ledger.invalidate()
        _ = try await ledger.release(token, at: .suspension)
        return try await task.value
    } catch {
        task.cancel()
        _ = try? await task.value
        throw error
    }
}
```

O recibo será `stale`, sem commit. Para efetivar uma operação sem invalidação: confirme o registro, libere `.suspension`, aguarde `token.resumption()`, libere `.commit` e faça join da task. Leia com `await ledger.snapshot()` e codifique com `try snapshot.canonicalJSON()`.

## Por que duas barreiras?

Isolamento de actor evita acesso simultâneo não sincronizado, mas não preserva premissas através de `await`. A primeira barreira demonstra invalidação de geração; a segunda torna observável e cancelável o intervalo entre retomada e commit, sem sleeps. Uma célula síncrona protegida por mutex trata cancelamento antes ou depois da instalação da continuação, sem criar task de encaminhamento.

A admissão reserva capacidade, waiter, registro, recibo futuro e dez posições de journal antes de suspender. Uma rejeição não altera o snapshot canônico. Evidências terminais não são descartadas. O primeiro cancelamento de aplicação tardio tem uma posição reservada e não desfaz commit.

Veja [contrato](docs/contract.md), [projeto e modelo de memória Swift](docs/design.md), [limites e evidências do ambiente](docs/build-notes.md) e [README em inglês](README.md).

## Limitações

- Máximos: capacidade 64, operações vivas/waiters 128, registros/recibos 1024, eventos 8192. Limites configurados menores podem rejeitar antes. Identificadores: 1–64 bytes de `[A-Za-z0-9._-]`.
- Todo token admitido deve ser executado e sua task aguardada, inclusive após cancelamento de aplicação. Abandonar token não libera reserva nem evidência.
- Uma task de execução e no máximo um observador de cada confirmação de registro/retomada por token. Esperas dos observadores não tratam cancelamento: o proprietário deve conduzir ou cancelar a operação.
- Determinismo somente nos cenários com confirmações explícitas. Sem promessa de FIFO, escalonamento, justiça, latência, consumo geral de memória ou vivacidade.
- Limpeza Swift é cooperativa. Timeout externo significa **incompleto**, nunca sucesso. O launcher de subprocessos limita saída e prazos, mas não garante encerrar processos irrecuperáveis no kernel ou ferramentas que escapem da sessão.
- Sem persistência, recuperação de falhas, actors distribuídos, carregamento de executáveis arbitrários, benchmark, UI, alegação de conformidade ampla ou qualificação de outras plataformas.

Código original: MIT © 2026 Lofrano Tecnologia. Licenças do Swift/toolchain/runtime são separadas em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Contato geral na [página oficial](https://lofranotecnologia.com.br); relatos de segurança no canal privado indicado em [SECURITY.md](SECURITY.md).
