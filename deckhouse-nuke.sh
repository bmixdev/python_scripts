#!/usr/bin/env bash
# deckhouse-nuke.sh — Полный сброс Deckhouse-кластера на ноде
# Автор: you+me
# Требования: root, bash 4+, systemd
set -Eeuo pipefail

############################################
#            Конфигурация/опции
############################################
YES=false
DRY_RUN=false
KEEP_IPTABLES=false
KEEP_CNI=false
KEEP_CRI=false
KEEP_PKI=false
ONLY_K8S=false
ONLY_D8=false

API_PORT_DEFAULT=6443

############################################
#            Утилиты/оформление
############################################
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_mag=$'\033[35m'; c_cyn=$'\033[36m'

log()   { printf "%s[%s]%s %s\n" "$c_cyn" "$1" "$c_reset" "${*:2}"; }
info()  { log INFO "$@"; }
warn()  { log "${c_yel}WARN$c_cyn" "$@"; }
err()   { log "${c_red}ERROR$c_cyn" "$@"; }
ok()    { printf "%s[ OK ]%s %s\n" "$c_grn" "$c_reset" "$*"; }

run() {
  if $DRY_RUN; then
    printf "%s[dry-run]%s %s\n" "$c_mag" "$c_reset" "$*"
  else
    eval "$@"
  fi
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Запусти как root (sudo)."
    exit 1
  fi
}

trap 'err "Скрипт прерван. Код: $?"; exit 1' ERR

############################################
#            Парсинг аргументов
############################################
usage() {
  cat <<EOF
Использование: $0 [опции]

Опции:
  -y, --yes                 не спрашивать подтверждение
  -n, --dry-run             ничего не удалять, только показывать действия
      --keep-iptables       не трогать iptables/nftables
      --keep-cni            не удалять CNI-интерфейсы и каталоги
      --keep-cri            не удалять containerd/docker каталоги
      --keep-pki            не удалять /etc/kubernetes/pki
      --only-k8s            удалить только Kubernetes/etcd/CRI/CNI (без Deckhouse)
      --only-d8             удалить только Deckhouse-артефакты (без kubeadm reset)
  -h, --help                показать помощь

Примеры:
  sudo $0 -y
  sudo $0 --dry-run
  sudo $0 -y --keep-iptables --only-k8s
EOF
}

ARGS=("$@")
while (("$#")); do
  case "$1" in
    -y|--yes) YES=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    --keep-iptables) KEEP_IPTABLES=true ;;
    --keep-cni) KEEP_CNI=true ;;
    --keep-cri) KEEP_CRI=true ;;
    --keep-pki) KEEP_PKI=true ;;
    --only-k8s) ONLY_K8S=true ;;
    --only-d8) ONLY_D8=true ;;
    -h|--help) usage; exit 0 ;;
    *) err "Неизвестная опция: $1"; usage; exit 2 ;;
  esac
  shift
done

if $ONLY_K8S && $ONLY_D8; then
  err "--only-k8s и --only-d8 взаимоисключающие."
  exit 2
fi

############################################
#            Детект окружения
############################################
need_root

HAS_CMD() { command -v "$1" >/dev/null 2>&1; }
SYSCTL()  { run "systemctl $* || true"; }

CRI="none"
if HAS_CMD docker && systemctl is-active --quiet docker 2>/dev/null; then
  CRI="docker"
elif HAS_CMD containerd && systemctl is-active --quiet containerd 2>/dev/null; then
  CRI="containerd"
elif systemctl list-units --type=service --all | grep -qE 'containerd|docker'; then
  # сервис есть, но не активен
  if systemctl list-units | grep -q containerd; then CRI="containerd"; fi
  if systemctl list-units | grep -q docker; then CRI="docker"; fi
fi

info "Обнаружен CRI: ${CRI}"

############################################
#            Резюме действий
############################################
info "План действий:"
$ONLY_D8 || echo " - kubeadm reset -f (если доступен), остановка kubelet, удаление /etc/kubernetes /var/lib/etcd и др."
$ONLY_K8S || echo " - остановка сервиса deckhouse, удаление /opt/ /var/lib/ /etc/ артефактов Deckhouse"
$KEEP_CRI   || echo " - очистка CRI (${CRI}) каталогов"
$KEEP_CNI   || echo " - удаление CNI-интерфейсов и каталогов"
$KEEP_IPTABLES || echo " - сброс iptables/nftables"
$KEEP_PKI   && echo " - сохранить /etc/kubernetes/pki (не удалять)"

if ! $YES; then
  read -r -p "$(printf '%s?%s Продолжить (yes/NO): ' "$c_yel" "$c_reset")" ans
  [[ "${ans,,}" == "yes" ]] || { warn "Отмена по запросу пользователя."; exit 0; }
fi

############################################
#            Шаги удаления
############################################

# 1) Остановить Deckhouse (если есть)
if ! $ONLY_K8S; then
  info "Останавливаю Deckhouse (если установлен)..."
  SYSCTL stop deckhouse
  SYSCTL disable deckhouse
  run "rm -f /etc/systemd/system/deckhouse.service"
fi

# 2) Остановить kubelet
$ONLY_D8 || {
  info "Останавливаю kubelet..."
  SYSCTL stop kubelet
  SYSCTL disable kubelet
}

# 3) kubeadm reset
if ! $ONLY_D8 && HAS_CMD kubeadm; then
  info "kubeadm reset -f..."
  run "kubeadm reset -f || true"
else
  $ONLY_D8 || warn "kubeadm не найден — пропускаю reset."
fi

# 4) Остановить CRI
if ! $ONLY_D8; then
  case "$CRI" in
    docker)
      info "Останавливаю docker..."
      SYSCTL stop docker
      SYSCTL disable docker
      ;;
    containerd)
      info "Останавливаю containerd..."
      SYSCTL stop containerd
      SYSCTL disable containerd
      ;;
    *)
      warn "CRI не активен или не обнаружен."
      ;;
  esac
fi

# 5) Удаление директорий
K8S_DIRS=(/etc/kubernetes /var/lib/etcd /var/lib/kubelet)
CNI_DIRS=(/var/lib/cni /etc/cni /opt/cni)
CRI_DIRS_DOCKER=(/var/lib/docker /etc/docker)
CRI_DIRS_CONTAINERD=(/var/lib/containerd /etc/containerd)
D8_DIRS=(/opt/deckhouse /var/lib/deckhouse /etc/deckhouse /var/log/deckhouse /usr/local/bin/deckhouse* )

# kubeconfig-и пользователя
USER_KUBES=(/root/.kube "$HOME/.kube")

if ! $ONLY_D8; then
  info "Удаляю каталоги Kubernetes..."
  for d in "${K8S_DIRS[@]}"; do run "rm -rf $d"; done
  # PKI сохранить?
  $KEEP_PKI && run "mkdir -p /etc/kubernetes && echo '(pki сохранён пользователем — пропускаю)' >/dev/null" || true
fi

if ! $ONLY_K8S; then
  info "Удаляю каталоги Deckhouse..."
  for d in "${D8_DIRS[@]}"; do run "rm -rf $d"; done
  run "rm -f /etc/systemd/system/deckhouse.service"
fi

if ! $ONLY_D8 && ! $KEEP_CNI; then
  info "Удаляю каталоги CNI..."
  for d in "${CNI_DIRS[@]}"; do run "rm -rf $d"; done
fi

if ! $ONLY_D8 && ! $KEEP_CRI; then
  case "$CRI" in
    docker)
      info "Удаляю каталоги Docker..."
      for d in "${CRI_DIRS_DOCKER[@]}"; do run "rm -rf $d"; done
      ;;
    containerd|none)
      info "Удаляю каталоги containerd (если были)..."
      for d in "${CRI_DIRS_CONTAINERD[@]}"; do run "rm -rf $d"; done
      # На некоторых установках мог быть docker раньше
      for d in "${CRI_DIRS_DOCKER[@]}"; do run "rm -rf $d"; done
      ;;
  esac
fi

info "Удаляю kubeconfig-и пользователя..."
for d in "${USER_KUBES[@]}"; do run "rm -rf $d"; done

# 6) Сетевые интерфейсы CNI
if ! $ONLY_D8 && ! $KEEP_CNI; then
  info "Удаляю CNI-интерфейсы (если есть)..."
  # На всякий случай набор распространённых имён
  CNI_IFACES=(cni0 flannel.1 flannel-wg cilium_host cilium_net weave bridge cali0)
  for i in "${CNI_IFACES[@]}"; do run "ip link delete $i 2>/dev/null || true"; done
  # Агрессивная зачистка calico/cilium/vxlan интерфейсов
  run "ip -o link show | grep -E 'cilium|cali|vxlan.calico|flannel|cni' | awk -F: '{print \$2}' | xargs -r -n1 -I{} bash -c 'ip link delete \"{}\" 2>/dev/null || true'"
fi

# 7) iptables/nftables
if ! $ONLY_D8 && ! $KEEP_IPTABLES; then
  info "Сбрасываю iptables/nftables..."
  if HAS_CMD iptables; then
    run "iptables -F || true"
    run "iptables -t nat -F || true"
    run "iptables -t mangle -F || true"
    run "iptables -X || true"
  fi
  if HAS_CMD ip6tables; then
    run "ip6tables -F || true"
    run "ip6tables -t nat -F || true"
    run "ip6tables -t mangle -F || true"
    run "ip6tables -X || true"
  fi
  if HAS_CMD nft; then
    run "nft flush ruleset || true"
  fi
fi

# 8) systemd daemon-reload
info "Обновляю systemd daeomon..."
run "systemctl daemon-reload || true"

# 9) Проверки/сводка
info "Проверка остаточных процессов..."
run "ps aux | grep -E 'kube|etcd|deckhouse' | grep -v grep || true"
info "Проверка порта API (${API_PORT_DEFAULT})..."
run "ss -tunlp | grep :${API_PORT_DEFAULT} || true"

ok "Готово. Нода очищена. Можно запускать установку заново."
$DRY_RUN && warn "Это был dry-run: ничего не удалено."
