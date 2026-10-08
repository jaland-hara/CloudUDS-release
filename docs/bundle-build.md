# Сборка пакета выпуска вручную

Пакет выпуска `cloududs-<версия>.tar` обычно собирают и публикуют два скрипта приватного репозитория `cloududs`:
`release/build-bundle.sh` (сборка, манифест, подпись) и `release/publish.sh` (выпуск на GitHub, документация, очистка).
Здесь те же шаги отдельными командами — если скрипт недоступен, ломается на новой машине или нужно понять, что он
делает. Команды повторяют скрипты: пакет, собранный по этой инструкции, не отличается от собранного скриптом.

## Этапы

| # | Этап | Где | Результат |
|---|---|---|---|
| 1 | Подготовка: ключ, дерево git, проверки, сборочная машина | рабочая и сборочная машины | всё готово к сборке |
| 2 | Клиенты сотрудников и агент UDS | сборочные ВМ клиентов | файлы в `$CLIENTS_DIR` и `$ACTOR_DIR` |
| 3 | Образы контейнеров | сборочная машина | `cloududs/<образ>:<версия>` в Docker |
| 4 | Каталог пакета: образы, код, файлы | сборочная машина | `$B/$V/…` |
| 5 | Манифест | сборочная машина | `manifest.json` |
| 6 | Подпись | машина с ключом | `manifest.sig` |
| 7 | Пакет | сборочная машина | `$B/cloududs-$V.tar` |
| 8 | Проверка пакета | любая | то же, что проверит `install.sh` |
| 9 | Публикация | репозиторий выпусков и GitHub Releases | выпуск `v<версия>`, `install.sh`, документация |
| 10 | Проверка выпуска | стенд | чистая установка и обновление с прежней версии |

## Что получается

`cloududs-<версия>.tar` — один tar без сжатия:

```
manifest.json            версия, коммит, время сборки, sha256 и размер каждого файла, образы с ID
manifest.sig             подпись Ed25519 файла manifest.json
code.tar.gz              deploy/run-role.sh, deploy/roles, deploy/tools, installer/, panel/deploy/config.example.yaml,
                         docs/diagrams/arch-*.svg
images/<имя>.tar.zst     docker save образа (теги <версия> и latest), сжатие zstd -10
files/actor/             агент UDS для эталонов: udsactor-linux.tgz, udsactor-win64.zip
files/clients/           клиенты для сотрудников: UDSLauncher-5.0.0.pkg, UDSLauncher-5.0.0-win64.zip, *.rpm, *.deb
```

Образы: `broker panel dbproxy tunnel keepalived guacamole guacd installer` (свои) и `memcached:1.6-alpine` (с Docker
Hub как есть). Размер пакета ~1,5 ГБ (GitHub принимает файл выпуска до 2 ГБ).

`manifest.json`:

```json
{"format": 1, "product": "cloududs", "version": "0.1.0-rc.32", "git": "c8142c4", "created": "2026-10-07T12:00:00Z",
 "files":  {"code.tar.gz": {"sha256": "…", "size": 123}, "images/broker.tar.zst": {"sha256": "…", "size": 456}, "…": {}},
 "images": {"broker": {"file": "images/broker.tar.zst", "ref": "cloududs/broker:0.1.0-rc.32", "id": "sha256:…", "size": 456}}}
```

В `files` — все файлы пакета, кроме самих `manifest.*`. Мастер установки по `images` знает, какой образ грузить на какие
узлы, и сверяет ID после загрузки.

**Версия** — `X.Y.Z` или `X.Y.Z-метка` (например `0.1.0-rc.32`, `0.1.0-dev.7`). Выпуск с меткой (любой символ `-`)
публикуется как pre-release. Порядок версий для мастера и очистки: окончательная > `rc` > `dev`.

## 1. Подготовка

**Машины.**

- **Рабочая машина:** клон `cloududs` на нужном коммите, `git`, `python3`, `ssh`, `tar`. С неё код уходит на сборочную
  машину.
- **Сборочная машина:** Linux amd64, Docker с **buildx** (BuildKit) — Dockerfile держат загрузки pip, cargo и Maven в
  кэшах BuildKit; `zstd`, `python3`, 30+ ГБ свободно (пакет ~1,5 ГБ, плюс образы и кэш). На Ubuntu:
  `sudo apt install docker.io docker-buildx zstd`.
- **Машина с ключом подписи** (не сборочная; обычно рабочая): `openssl` 3.x и закрытый ключ Ed25519. Ключ на сборочную
  машину не попадает: манифест едет к ключу, подпись — обратно.
- **Сборочные ВМ клиентов** (этап 2) — только если клиенты меняются в этом выпуске.

**Переменные** в командах ниже:

```bash
V=0.1.0-rc.33                      # версия выпуска
B=/var/tmp/cloududs-build          # каталог сборок на сборочной машине
H=build-host                       # сборочная машина (имя из ~/.ssh/config)
KEY=~/keys/cloududs-release.key    # закрытый ключ подписи (на машине с ключом)
ACTOR_DIR=~/release/actor          # агент UDS: udsactor-linux.tgz, udsactor-win64.zip
CLIENTS_DIR=~/release/clients      # клиенты сотрудников (этап 2)
S() { ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "$H" "$@"; }   # keepalive: тихая сборка иначе рвёт связь через jump
```

**Проверки на рабочей машине, из корня репозитория.**

```bash
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]] || echo "версия: X.Y.Z[-метка]"
# ключ — тот, чью открытую половину несёт install.sh
diff <(openssl pkey -in "$KEY" -pubout) installer/release-pub.pem && echo "ключ ok"
# коммит для манифеста; незакоммиченные изменения дают метку +dirty — для выпуска дерево должно быть чистым
GIT=$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo "+dirty"); echo $GIT
# описание сети в документации совпадает с кодом мастера
python3 installer/tools/gen-network-model.py --check
# заметки к выпуску: идут первыми в описании выпуска на GitHub
test -f release/notes/$V.md || echo "нет release/notes/$V.md"
```

**Сборочная машина.**

```bash
# свежая ВМ первые минуты ставит обновления и перезапускает docker посреди сборки: дождаться, пока apt освободится
S "while pgrep -f '/usr/bin/[u]nattended-upgrade( |$)|[a]pt-get |/usr/bin/[d]pkg' >/dev/null; do sleep 5; done; sudo docker buildx version"
# каталог сборки этой версии (заново, если был)
S "sudo install -d -m 755 $B && sudo rm -rf $B/$V && sudo install -d -m 755 $B/$V/images $B/$V/files/actor $B/$V/files/clients"
# место: держите не больше двух прошлых сборок (опубликованные лежат в GitHub Releases)
S "ls -1t $B"   # лишние: sudo rm -rf $B/<версия> $B/cloududs-<версия>.tar
```

## 2. Клиенты и агент

Клиенты собираются отдельно и складываются в `$CLIENTS_DIR`. Пересобирать их нужно, только если в выпуске меняется
клиент (`client/patches`, `client/build/*`); иначе берутся файлы прошлого выпуска.

| Платформа | Где и как | Результат (имя в пакете) |
|---|---|---|
| macOS | Mac: FreeRDP 3.27.1 с патчами — `client/build/macos/build-freerdp.sh`; затем в `uds-client`: `FREERDP_ROOT=… python3 building/macos/build-pkg.py` | `building/macos/dist/UDSLauncher-DEVEL.pkg` → `UDSLauncher-5.0.0.pkg` |
| Windows | сборочная ВМ Windows: `client/build/run-win-linux.sh` (`WIN_ONLY=1` — только Windows), ожидание — `client/build/wait-win-linux.sh` | `C:\build\UDSLauncher-5.0.0-win64.zip` |
| РЕД ОС 8, Astra SE 1.8 | сборочная ВМ РЕД ОС, тот же `run-win-linux.sh` (`redos-*.sh`, `deb12-build.sh`) | `udslauncher-5.0.0-1.redos8.x86_64.rpm`, `udslauncher_5.0.0-1astra18_amd64.deb` |
| Альт p11 | сборочная ВМ Альт, тот же `run-win-linux.sh` (`alt-client.sh`) | `udslauncher-5.0.0-alt1.p11.x86_64.rpm` |

- Исходники: `uds-client` и `freerdp-integration` (VirtualCable) с патчами `client/patches`; FreeRDP 3.27.1 с патчами
  `client/build/freerdp-patches` (для Windows ещё `client/build/windows/patches`). MIT krb5 для Windows —
  `client/build/windows/krb5-port/build-krb5.ps1`, собирается один раз. Подробности Linux-сборки —
  `client/build/linux/README.md`.
- Имена важны: в пакет попадают только файлы `UDSLauncher*` / `udslauncher*` (портал раздаёт их по этому шаблону).
- Агент UDS для эталонов (`udsactor-linux.tgz`, `udsactor-win64.zip`) — внешний артефакт в `$ACTOR_DIR`, меняется редко
  (патчи `actor/patches`, сборка Linux — `actor/build`).

## 3. Образы

Для каждого образа — свой контекст (как в `deploy/build-image.sh`):

| Образ | Контекст (пути от корня репозитория) |
|---|---|
| broker | `broker/`, `deploy/images/broker/` |
| panel | `panel/`, `deploy/images/panel/`, `deploy/tools/vdi-restore.py` |
| guacamole | `html5/guac-ext/`, `deploy/images/guacamole/` |
| installer | `installer/`, `deploy/images/installer/` |
| dbproxy, tunnel, keepalived, guacd | `deploy/images/<образ>/` |

Версии исходников сторонних частей (брокер и туннель OpenUDS, Guacamole) закреплены в Dockerfile (`ARG …_COMMIT`,
`GUAC_VERSION`) — их меняет только обновление исходников, не сборка.

```bash
# для каждого образа: контекст на сборочную машину с сохранением путей и docker build
for I in broker panel dbproxy tunnel keepalived guacamole guacd installer; do
  case $I in
    broker) CTX="broker deploy/images/broker" ;;
    panel) CTX="panel deploy/images/panel deploy/tools/vdi-restore.py" ;;
    guacamole) CTX="html5/guac-ext deploy/images/guacamole" ;;
    installer) CTX="installer deploy/images/installer" ;;
    *) CTX="deploy/images/$I" ;;
  esac
  # уже собранный с этой версией образ не собирать заново (упавшая сборка продолжается с места)
  S "sudo docker image inspect cloududs/$I:$V >/dev/null 2>&1" && { echo "$I: уже собран"; continue; }
  COPYFILE_DISABLE=1 tar czf - --no-xattrs --exclude='._*' --exclude=__pycache__ $CTX \
    | S "rm -rf /tmp/ctx-$I && mkdir -p /tmp/ctx-$I && tar xzf - -C /tmp/ctx-$I && cd /tmp/ctx-$I &&
         sudo DOCKER_BUILDKIT=1 docker build -q --pull --no-cache -f deploy/images/$I/Dockerfile -t cloududs/$I:$V -t cloududs/$I:latest ."
done
S "sudo docker pull -q memcached:1.6-alpine"
```

- `--pull --no-cache` (в скрипте — `FRESH=1`): свежие базовые образы и пакеты ОС, закрывает уязвимости. Обязательно для
  окончательных выпусков и не реже раза в неделю; промежуточный rc можно без них — слои из кэша. Кэши pip, cargo и Maven
  в BuildKit при этом остаются; сбросить их — `docker builder prune --filter type=exec.cachemount`.
- Взять образы прошлой версии без сборки (в скрипте — `REUSE=<старая>`, `REBUILD="…"` — какие собрать заново):
  `S "sudo docker tag cloududs/<образ>:<старая> cloududs/<образ>:$V"` для каждого неменявшегося образа.
- Медленный выход в интернет — прокси для сборки: `--build-arg http_proxy=… --build-arg https_proxy=…` и `no_proxy` для
  зеркал ОС, crates.io, GitHub, Maven и Apache (список — в `deploy/build-image.sh`). Значение прокси с паролем не
  передавайте в командной строке: скрипт кладёт его в файл 0600 на сборочной машине.

## 4. Каталог пакета

```bash
# образы → zstd
S "for i in broker panel dbproxy tunnel keepalived guacamole guacd installer; do
     sudo docker save cloududs/\$i:$V cloududs/\$i:latest | zstd -q -T0 -10 | sudo tee $B/$V/images/\$i.tar.zst >/dev/null
   done
   sudo docker save memcached:1.6-alpine | zstd -q -T0 -10 | sudo tee $B/$V/images/memcached.tar.zst >/dev/null"

# код: то, что нужно мастеру установки (исходников брокера и кабинета нет — они в образах)
COPYFILE_DISABLE=1 tar czf - --no-xattrs --exclude='._*' --exclude=__pycache__ \
  deploy/run-role.sh deploy/roles deploy/tools installer panel/deploy/config.example.yaml docs/diagrams/arch-*.svg \
  | S "sudo tee $B/$V/code.tar.gz >/dev/null"

# агент UDS и клиенты
for f in "$ACTOR_DIR"/udsactor-*; do S "sudo tee $B/$V/files/actor/$(basename "$f") >/dev/null" < "$f"; done
for f in "$CLIENTS_DIR"/[Uu][Dd][Ss][Ll]auncher*; do S "sudo tee $B/$V/files/clients/$(basename "$f") >/dev/null" < "$f"; done
```

## 5. Манифест

На сборочной машине (нужен docker — записать ID образов). Коммит `$GIT` — с рабочей машины (этап 1): на сборочной
машине репозитория нет.

```bash
S "sudo python3 - $B/$V '$V' '$GIT' 'memcached:1.6-alpine'" <<'PY'
import hashlib, json, pathlib, subprocess, sys, time
d = pathlib.Path(sys.argv[1]); ver, git, ext = sys.argv[2], sys.argv[3], sys.argv[4].split()
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
files = {str(p.relative_to(d)): {"sha256": sha(p), "size": p.stat().st_size}
         for p in sorted(d.rglob("*")) if p.is_file() and not p.name.startswith("manifest")}
images = {}
for p in sorted((d / "images").glob("*.tar.zst")):
    n = p.name[:-8]
    ref = next((e for e in ext if e.split(":")[0] == n), f"cloududs/{n}:{ver}")
    iid = subprocess.run(["docker", "image", "inspect", "-f", "{{.Id}}", ref], capture_output=True, text=True).stdout.strip()
    images[n] = {"file": f"images/{p.name}", "ref": ref, "id": iid, "size": p.stat().st_size}
m = {"format": 1, "product": "cloududs", "version": ver, "git": git,
     "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "files": files, "images": images}
(d / "manifest.json").write_text(json.dumps(m, indent=1, ensure_ascii=False))
PY
```

## 6. Подпись

На машине с ключом:

```bash
T=$(mktemp -d)
S "cat $B/$V/manifest.json" > $T/manifest.json
openssl pkeyutl -sign -inkey "$KEY" -rawin -in $T/manifest.json -out $T/manifest.sig
openssl pkeyutl -verify -pubin -inkey installer/release-pub.pem -rawin -in $T/manifest.json -sigfile $T/manifest.sig
S "sudo tee $B/$V/manifest.sig >/dev/null" < $T/manifest.sig
rm -rf $T
```

После подписи файлы в каталоге менять нельзя: любое изменение — пересчитать манифест (этап 5) и подписать заново.

## 7. Пакет

```bash
S "cd $B/$V && sudo tar cf $B/cloududs-$V.tar manifest.json manifest.sig code.tar.gz images files && ls -la $B/cloududs-$V.tar"
```

Состав — ровно эти пять элементов: `install.sh` сначала достаёт `manifest.json` и `manifest.sig`, проверяет подпись, затем
распаковывает всё и отклоняет пакет, если какой-то файл не совпал по sha256 или **лишний** (не указан в манифесте).

## 8. Проверка пакета

То же, что сделает `install.sh` до установки (нужен `release-pub.pem` из репозитория выпусков или `installer/`):

```bash
mkdir /tmp/chk && tar -xf cloududs-$V.tar -C /tmp/chk
openssl pkeyutl -verify -pubin -inkey release-pub.pem -rawin -in /tmp/chk/manifest.json -sigfile /tmp/chk/manifest.sig
python3 - /tmp/chk "$V" <<'PY'
import hashlib, json, pathlib, sys
w, ver = pathlib.Path(sys.argv[1]), sys.argv[2]; m = json.loads((w / "manifest.json").read_text())
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()
bad = [n for n, f in m["files"].items() if not (w / n).is_file() or sha(w / n) != f["sha256"]]
extra = {str(p.relative_to(w)) for p in w.rglob("*") if p.is_file()} - set(m["files"]) - {"manifest.json", "manifest.sig"}
need = {"broker", "panel", "dbproxy", "tunnel", "keepalived", "guacamole", "guacd", "installer", "memcached"} - set(m["images"])
print("версия:", m["version"], "коммит:", m["git"])
print("ok" if not (bad or extra or need or m["version"] != ver or m["git"].endswith("+dirty"))
      else f"не совпали: {bad}; лишние: {sorted(extra)}; нет образов: {sorted(need)}")
PY
zstd -dc /tmp/chk/images/installer.tar.zst | sudo docker load -q   # образ мастера загружается
rm -rf /tmp/chk
```

## 9. Публикация

Выпуски публикуются в репозитории выпусков `jaland-hara/CloudUDS-release`: файлы выпуска на GitHub Releases, в самом
репозитории — `install.sh`, открытый ключ и документация. Нужен токен GitHub с правом **Contents: write только на этот
репозиторий** (fine-grained). Токен не передавайте в командной строке и не печатайте: только из файла с правами 0600.

**9.1. `install.sh` и ключ.** В клоне репозитория выпусков обновить `install.sh` и `release-pub.pem` из
`installer/` этого репозитория; если изменились — закоммитить и отправить.

**9.2. Документация.** `docs/` репозитория выпусков собирается из справки кабинета (`panel/frontend/app.js`) и документов
продукта:

```bash
node panel/tools/help-export.mjs <клон CloudUDS-release>/docs     # нужны node и pandoc (3.6+)
git -C <клон CloudUDS-release> add -A docs && git -C <клон CloudUDS-release> commit -m "docs from the cabinet help ($(git rev-parse --short HEAD))" && git -C <клон CloudUDS-release> push
```

Другая версия pandoc меняет оформление таблиц и блоков кода — получится большой дифф без изменений по смыслу.

**9.3. Описание выпуска** — заметки `release/notes/$V.md`, затем раздел «Пакет» со сведениями из манифеста. Описание
собирается на рабочей машине и уходит на сборочную (пакет остаётся там: 1,5 ГБ через рабочую машину не возить):

```bash
S "tar -xOf $B/cloududs-$V.tar manifest.json" > /tmp/manifest-$V.json
python3 - /tmp/manifest-$V.json release/notes/$V.md > /tmp/notes-$V.md <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); size = sum(i["size"] for i in m["images"].values()) / 1048576
print(open(sys.argv[2]).read().rstrip()); print(); print("### Пакет")
print(f"Сборка {m['created']}, коммит `{m['git']}`."); print()
print("Установка: см. README. Проверка подлинности — install.sh (подпись манифеста и sha256 файлов)."); print()
print("| Образ | Размер (zstd) |"); print("|---|---|")
for n, i in sorted(m["images"].items()):
    print(f"| {n} | {i['size'] / 1048576:.0f} МБ |")
print(); print(f"Всего образов: {size:.0f} МБ.")
PY
S "cat > /tmp/notes-$V.md" < /tmp/notes-$V.md
```

**9.4. Выпуск и файлы** (на сборочной машине; токен — в файле `~/gh-token` с правами 0600):

```bash
S "set -e; cd $B; REPO=jaland-hara/CloudUDS-release
  umask 077; { printf 'Authorization: Bearer '; cat ~/gh-token; } > /tmp/.gh
  python3 -c 'import json,sys; v=sys.argv[1]; print(json.dumps({\"tag_name\": \"v\"+v, \"target_commitish\": \"main\", \"name\": \"v\"+v,
    \"body\": open(sys.argv[2]).read(), \"prerelease\": \"-\" in v}))' $V /tmp/notes-$V.md > /tmp/body.json
  ID=\$(curl -sf -X POST -H @/tmp/.gh -H 'Accept: application/vnd.github+json' https://api.github.com/repos/\$REPO/releases -d @/tmp/body.json \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"id\"])')
  # install.sh — из этого же пакета, чтобы совпадал с ним
  tar -xOf cloududs-$V.tar code.tar.gz | tar -xzO installer/install.sh > /tmp/install.sh
  curl -sf -o /dev/null -X POST -H @/tmp/.gh -H 'Content-Type: application/x-tar' -T cloududs-$V.tar \
       \"https://uploads.github.com/repos/\$REPO/releases/\$ID/assets?name=cloududs-$V.tar\"
  curl -sf -o /dev/null -X POST -H @/tmp/.gh -H 'Content-Type: text/x-shellscript' -T /tmp/install.sh \
       \"https://uploads.github.com/repos/\$REPO/releases/\$ID/assets?name=install.sh\"
  rm -f /tmp/.gh /tmp/body.json /tmp/install.sh /tmp/notes-$V.md; echo \"выпуск \$ID\""
```

Через веб-интерфейс то же: Releases → Draft a new release → тег `v<версия>` на `main` → описание из 9.3 → для версии с
меткой отметить «Set as a pre-release» → прикрепить `cloududs-<версия>.tar` и `install.sh` → Publish.

**9.5. Очистка.** Остаются два последних предварительных выпуска (`-rc`, `-dev`) и все окончательные; более старые
предварительные удаляются вместе с тегом (в скрипте — `release/prune.sh`, `KEEP=2`): `DELETE /repos/<репозиторий>/releases/<id>`,
затем `DELETE /repos/<репозиторий>/git/refs/tags/v<версия>`. Любой удалённый выпуск можно собрать снова из его коммита
(поле `git` манифеста).

## 10. Проверка выпуска

- `install.sh` без версии ставит **наибольшую** версию из опубликованных, включая pre-release (окончательная > rc > dev;
  черновики не учитываются). Опубликованный выпуск сразу становится «последним» для новых установок — публикуйте
  проверенный пакет; черновик выпуска (draft) можно держать, пока идёт проверка.
- **Чистая установка:** новая ВМ установщика, `install.sh` с GitHub, все экраны мастера, затем вход сотрудника на стол
  (приложение и браузер).
- **Обновление:** стенд на прежней версии — `sudo cloududs-installer <версия>`, затем «Обновление» в мастере (UPGRADE.md
  репозитория выпусков); после — «Состояние системы» зелёное, сеансы работают.

## Типичные проблемы

| Что видно | Причина | Что делать |
|---|---|---|
| `нет docker buildx (BuildKit)` | на сборочной машине старый docker build | `apt install docker-buildx` (Ubuntu) или `docker-buildx-plugin` (репозиторий Docker) |
| сборка зависла без вывода | ssh через jump без keepalive оборвался | `ServerAliveInterval=30` (функция `S` выше), запустить снова — собранные образы не пересобираются |
| сборка упала на `docker` в первые минуты новой ВМ | unattended-upgrades перезапустил docker | дождаться apt (этап 1) и повторить |
| `install.sh`: «подпись пакета неверна» | подписан другой ключ или манифест менялся после подписи | сверить ключ с `installer/release-pub.pem`, подписать заново (этапы 5–6) |
| `install.sh`: «контрольные суммы не совпали» (в журнале — «не совпали» и «лишние») | файл в каталоге добавлен или изменён после манифеста | пересчитать манифест и подписать заново, собрать tar (этапы 5–7) |
| загрузка файла выпуска 422 | файл с таким именем уже есть у выпуска | удалить старый файл выпуска (`DELETE /repos/<репозиторий>/releases/assets/<id>`) и загрузить снова |
| `toomanyrequests` при `docker pull` | лимит Docker Hub для анонимных загрузок | `docker login` на сборочной машине или повторить позже |

## Соответствие скриптам

| Переменная `build-bundle.sh` | Что делает | Здесь |
|---|---|---|
| `FRESH=1` | `--pull --no-cache` для образов | этап 3 |
| `SKIP_BUILD=1` | не собирать, взять `cloududs/<образ>:<версия>` с машины | пропустить сборку на этапе 3 |
| `REUSE=<старая>`, `REBUILD="…"` | перетегировать образы старой версии, собрать только перечисленные | `docker tag` на этапе 3 |
| `ACTOR_DIR`, `CLIENTS_DIR` | откуда взять агент UDS и клиентов | этапы 2 и 4 |
| `BUILD_PROXY` | прокси для PyPI при сборке образов | этап 3 |
| `SIGN_KEY` | закрытый ключ подписи | `$KEY`, этап 6 |

`publish.sh <машина> <версия> [--dry-run]` — этап 9 целиком; `--dry-run` показывает описание и что изменится в
репозитории выпусков, ничего не публикуя.

---
[Оглавление](README.md)
