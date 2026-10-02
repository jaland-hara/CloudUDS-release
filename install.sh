#!/bin/bash
# cloududs: installer VM bootstrap and control. Ubuntu 24.04, run as root.
#
#   install.sh [X.Y.Z | URL | file]   install or upgrade the installer from a release bundle:
#                                 nothing — the latest release of github.com/jaland-hara/CloudUDS-release,
#                                 X.Y.Z — that release, https://…/cloududs-X.Y.Z.tar, or /path/cloududs-X.Y.Z.tar (carried in)
#   cloududs-installer link      a new one-time sign-in link (the old one stops working)
#   cloududs-installer status | logs | restart
#
# What it does: checks the bundle signature (Ed25519, the key below) and every file's sha256 before unpacking;
# unpacks to /opt/cloududs/releases/<version> (current → the active one); loads the installer image; runs the wizard
# on 127.0.0.1:8200 (open it through an SSH tunnel). Data (inventory, encrypted secrets, the SSH key to the nodes,
# logs): /var/lib/cloududs-installer. Nodes get everything from this VM — the bundle carries ready images.
set -euo pipefail
PUB='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAGwZLg7ikstwyZrsqSG8SfAx7sJtGeeSx/kaJMvMHPYw=
-----END PUBLIC KEY-----'
RELEASES=https://github.com/jaland-hara/CloudUDS-release; RELAPI=https://api.github.com/repos/jaland-hara/CloudUDS-release
ROOT=/opt/cloududs; DATA=/var/lib/cloududs-installer; CNAME=cloududs-installer; PORT=8200; UID_I=995
say(){ echo "[cloududs] $*"; }
die(){ echo "[cloududs] ОШИБКА: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "запустите от root (sudo)"

token() { (umask 077; head -c 48 /dev/urandom | base64 | tr -d '+/=\n' | head -c 32 > $DATA/access_token); chown $UID_I $DATA/access_token; }
link() {
  [ -d $DATA ] || die "установщик не установлен"
  token
  local ip; ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p')
  echo
  echo "  Мастер слушает только 127.0.0.1:$PORT этой ВМ. С компьютера администратора:"
  echo "    ssh -L $PORT:127.0.0.1:$PORT ${SUDO_USER:-ubuntu}@${ip:-<адрес этой ВМ>}"
  echo "  и откройте в браузере (ссылка одноразовая по смыслу — не пересылайте её):"
  echo "    http://127.0.0.1:$PORT/login?t=$(cat $DATA/access_token)"
  echo "  Новая ссылка: sudo cloududs-installer link"
  echo
}

run_container() {
  docker rm -f $CNAME >/dev/null 2>&1 || true
  # the same limits as the product containers: no capabilities, no privilege escalation, read-only root
  docker run -d --name $CNAME --restart unless-stopped -p 127.0.0.1:$PORT:8200 \
    -v $DATA:/data -v $ROOT/current:/bundle:ro \
    --cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp:size=256m --pids-limit 512 \
    "cloududs/installer:$1" >/dev/null
  for i in $(seq 1 30); do curl -sf -o /dev/null http://127.0.0.1:$PORT/healthz && return 0; sleep 1; done
  docker logs --tail 30 $CNAME; die "мастер не отвечает"
}

install_bundle() {
  local src=$1 work f ver
  . /etc/os-release; [ "$ID $VERSION_ID" = "ubuntu 24.04" ] || say "внимание: проверено на Ubuntu 24.04, здесь $ID $VERSION_ID"
  if ! command -v docker >/dev/null || ! command -v zstd >/dev/null; then
    say "пакеты: docker.io, zstd"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -yq docker.io zstd curl >/dev/null
    systemctl enable --now docker >/dev/null 2>&1
  fi
  install -d -m 755 $ROOT $ROOT/releases $ROOT/incoming
  if [ -z "$src" ]; then   # the newest release (pre-releases included while only -dev versions exist)
    # the highest version (GitHub lists releases by the tag commit date, not by version): final > rc > dev
    src=$(curl -fsS "$RELAPI/releases?per_page=100" | python3 -c '
import json, re, sys
def key(t):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)(?:-(dev|rc)\.?(\d+))?$", t)
    return (int(m[1]), int(m[2]), int(m[3]), {"dev": 0, "rc": 1, None: 2}[m[4]], int(m[5] or 0)) if m else (-1,)
tags = [r["tag_name"] for r in json.load(sys.stdin) if not r.get("draft")]
print(max(tags, key=key)[1:] if tags else "")') \
      || die "не удалось узнать последний выпуск ($RELEASES)"
    [ -n "$src" ] || die "выпусков пока нет"
  fi
  if [[ $src =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ]]; then src=${src#v}; src="$RELEASES/releases/download/v$src/cloududs-$src.tar"; fi
  case $src in
    http://*|https://*) f=$ROOT/incoming/$(basename "${src%%\?*}"); say "загрузка $src"; curl -fL --retry 3 --progress-bar -o "$f.part" "$src" || die "не удалось скачать"; mv "$f.part" "$f"; DOWNLOADED=$f ;;
    *) f=$(readlink -f "$src"); [ -f "$f" ] || die "нет файла $src" ;;
  esac
  work=$(mktemp -d $ROOT/incoming/unpack.XXXX); trap 'rm -rf "$work"' EXIT
  tar -xf "$f" -C "$work" manifest.json manifest.sig || die "это не пакет выпуска (нет manifest.json)"
  printf '%s\n' "$PUB" > "$work/pub.pem"
  openssl pkeyutl -verify -pubin -inkey "$work/pub.pem" -rawin -in "$work/manifest.json" -sigfile "$work/manifest.sig" >/dev/null 2>&1 \
    || die "подпись пакета неверна — пакет изменён или не от этого издателя"
  ver=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$work/manifest.json")
  [[ $ver =~ ^[0-9A-Za-z.+-]+$ ]] || die "странная версия в манифесте"
  say "пакет $ver: подпись верна, распаковка"
  tar -xf "$f" -C "$work"
  python3 - "$work" <<'PY' || die "контрольные суммы не совпали"
import hashlib, json, pathlib, sys
w = pathlib.Path(sys.argv[1]); m = json.loads((w / "manifest.json").read_text())
bad = []
for rel, meta in m["files"].items():
    p = (w / rel).resolve()
    if not str(p).startswith(str(w.resolve()) + "/") or not p.is_file():
        bad.append(rel + " (нет файла)")
        continue
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != meta["sha256"]:
        bad.append(rel)
extra = {str(p.relative_to(w)) for p in w.rglob("*") if p.is_file()} - set(m["files"]) - {"manifest.json", "manifest.sig", "pub.pem"}
if bad or extra:
    print("не совпали:", bad, "лишние:", sorted(extra)); sys.exit(1)
PY
  rm -f "$work/pub.pem"
  install -d -m 755 "$work/code"; tar -xzf "$work/code.tar.gz" -C "$work/code"
  rm -rf "$ROOT/releases/$ver"; mv "$work" "$ROOT/releases/$ver"; trap - EXIT; chmod 755 "$ROOT/releases/$ver"
  ln -sfn "releases/$ver" $ROOT/current.new && mv -T $ROOT/current.new $ROOT/current
  say "образ мастера"; zstd -dc "$ROOT/current/images/installer.tar.zst" | docker load -q >/dev/null
  install -d -m 700 -o $UID_I $DATA
  local first=; [ -f $DATA/access_token ] || { first=1; token; }
  # the VM's own address: the wizard finds its network and router in the cloud by it (the container sees only its bridge)
  ip -4 -o route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' > $DATA/host_ip; chown $UID_I $DATA/host_ip
  install -m 755 "$ROOT/current/code/installer/install.sh" /usr/local/sbin/cloududs-installer
  run_container "$ver"
  say "мастер $ver запущен"
  [ -n "${DOWNLOADED:-}" ] && rm -f "$DOWNLOADED"   # unpacked into releases/ — the archive is not needed any more
  if [ -n "$first" ]; then link; else say "ссылка входа прежняя; новая: sudo cloududs-installer link"; fi
  # keep the last three releases (never the active one)
  ls -1d $ROOT/releases/* | sort -V | head -n -3 | grep -vx "$ROOT/releases/$ver" | xargs -r rm -rf
}

case "${1:-}" in
  link) link ;;
  status) docker ps -a --filter name=$CNAME --format '{{.Names}} {{.Image}} {{.Status}}'; readlink $ROOT/current ;;
  logs) docker logs --tail 100 -f $CNAME ;;
  restart) docker restart $CNAME >/dev/null && say "перезапущен" ;;
  -h|--help) sed -n 2,13p "$0" ;;
  *) install_bundle "${1:-}" ;;
esac
