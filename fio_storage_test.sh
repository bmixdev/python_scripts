#сделал 💪 — скрипт принимает путь к каталогу, гоняет однопоточные и 4-поточные профили, выводит результаты и на экран, и в лог-файл (в каталоге теста). Временный тестовый файл удаляется, job-файл и логи остаются.
#!/bin/bash
# fio_storage_test.sh
# Использование:
#   ./fio_storage_test.sh /mnt/storage [--size 16G]
#   ./fio_storage_test.sh /mnt/storage [--size=16G]
#
# Вывод: на экран и в лог fio_results_YYYYmmdd_HHMMSS.log в каталоге теста

set -euo pipefail

if ! command -v fio >/dev/null 2>&1; then
  echo "fio не найден. Установи: sudo apt-get update && sudo apt-get install -y fio"
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "Использование: $0 <каталог для теста> [--size 16G]"
  exit 1
fi

TARGET_DIR="$1"; shift || true

# --- разбор флагов ---
USER_SIZE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --size)
      [ $# -ge 2 ] || { echo "Ошибка: после --size нужно указать значение (напр. 16G)"; exit 1; }
      USER_SIZE="$2"; shift 2;;
    --size=*)
      USER_SIZE="${1#--size=}"; shift;;
    *)
      echo "Неизвестный аргумент: $1"; exit 1;;
  esac
done

if [ ! -d "$TARGET_DIR" ]; then
  echo "Каталог не существует: $TARGET_DIR"
  exit 1
fi
if [ ! -w "$TARGET_DIR" ]; then
  echo "Нет прав на запись в каталог: $TARGET_DIR"
  exit 1
fi

# --- утилита: перевод размера в MiB (поддержка K,M,G,T, допускается ...iB/..B) ---
to_mib() {
  local s="${1^^}"
  s="${s//IB/}"; s="${s//B/}"   # убираем iB/B
  local num unit
  num="${s%[KMGT]}"; unit="${s:${#num}}"
  # если нет суффикса — считаем, что MiB
  case "$unit" in
    K) echo $(( (num + 1023) / 1024 ));;
    M|"") echo $(( num ));;
    G) echo $(( num * 1024 ));;
    T) echo $(( num * 1024 * 1024 ));;
    *) echo 0;;
  esac
}

# --- вычисление/проверка размера тестового файла ---
avail_kb=$(df -Pk "$TARGET_DIR" | awk 'NR==2{print $4}')
[ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] || { echo "Не удалось определить свободное место в $TARGET_DIR"; exit 1; }
avail_mib=$(( avail_kb / 1024 ))

MIN_MIB=512          # 512 MiB минимум
MAX_MIB=32768        # 32 GiB максимум

if [ -n "$USER_SIZE" ]; then
  req_mib=$(to_mib "$USER_SIZE")
  [ "$req_mib" -gt 0 ] || { echo "Некорректный размер в --size: $USER_SIZE"; exit 1; }
  if [ "$req_mib" -gt "$avail_mib" ]; then
    echo "Запрошенный размер ${USER_SIZE} больше доступного пространства (~${avail_mib}MiB) в $TARGET_DIR"
    exit 1
  fi
  FILE_SIZE="${USER_SIZE}"
else
  # авто-подбор ≈60% свободного, с ограничениями
  file_mib=$(( (avail_mib * 60) / 100 ))
  [ $file_mib -gt $MAX_MIB ] && file_mib=$MAX_MIB
  [ $file_mib -lt $MIN_MIB ] && file_mib=$MIN_MIB
  FILE_SIZE="${file_mib}M"
fi

TS="$(date +%Y%m%d_%H%M%S)"
TEST_FILE="$TARGET_DIR/fio_testfile"
JOB_FILE="$TARGET_DIR/fio_job_${TS}.fio"
LOG_FILE="$TARGET_DIR/fio_results_${TS}.log"

cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT

# Параметры профилей
RUNTIME=30            # сек на профиль
SEQ_BS=1M             # блок для последовательных операций
RAND_BS=4k            # блок для случайных операций
SEQ_IOD=4             # iodepth для последовательных
RAND_IOD=32           # iodepth для случайных

cat > "$JOB_FILE" <<EOF
[global]
ioengine=libaio
direct=1
time_based=1
runtime=${RUNTIME}
group_reporting=1
filename=${TEST_FILE}
size=${FILE_SIZE}
refill_buffers=1
fsync_on_close=1

# ================= Однопоточные =================
[seq_read_1job]
bs=${SEQ_BS}
rw=read
iodepth=${SEQ_IOD}
numjobs=1

[seq_write_1job]
bs=${SEQ_BS}
rw=write
iodepth=${SEQ_IOD}
numjobs=1

[rand_read_1job]
bs=${RAND_BS}
rw=randread
iodepth=${RAND_IOD}
numjobs=1

[rand_write_1job]
bs=${RAND_BS}
rw=randwrite
iodepth=${RAND_IOD}
numjobs=1

[rand_rw_1job]
bs=${RAND_BS}
rw=randrw
rwmixread=70
iodepth=${RAND_IOD}
numjobs=1

# ================= Многопоточные (4 jobs) =================
[seq_read_4job]
bs=${SEQ_BS}
rw=read
iodepth=${SEQ_IOD}
numjobs=4

[seq_write_4job]
bs=${SEQ_BS}
rw=write
iodepth=${SEQ_IOD}
numjobs=4

[rand_read_4job]
bs=${RAND_BS}
rw=randread
iodepth=${RAND_IOD}
numjobs=4

[rand_write_4job]
bs=${RAND_BS}
rw=randwrite
iodepth=${RAND_IOD}
numjobs=4

[rand_rw_4job]
bs=${RAND_BS}
rw=randrw
rwmixread=70
iodepth=${RAND_IOD}
numjobs=4
EOF

echo "=== FIO тест СХД ===" | tee "$LOG_FILE"
echo "Каталог: $TARGET_DIR" | tee -a "$LOG_FILE"
echo "Job-файл: $JOB_FILE" | tee -a "$LOG_FILE"
echo "Лог: $LOG_FILE" | tee -a "$LOG_FILE"
echo "Размер тестового файла (size): ${FILE_SIZE}" | tee -a "$LOG_FILE"
echo "Время на профиль: ${RUNTIME} c" | tee -a "$LOG_FILE"
echo "Начало: $(date '+%F %T')" | tee -a "$LOG_FILE"
echo "----------------------------------------" | tee -a "$LOG_FILE"

fio "$JOB_FILE" | tee -a "$LOG_FILE"

echo "----------------------------------------" | tee -a "$LOG_FILE"
echo "Готово. Временные данные удалены, результаты в: $LOG_FILE" | tee -a "$LOG_FILE"
echo "Job-файл сохранён: $JOB_FILE" | tee -a "$LOG_FILE"

#как запускать:

#chmod +x fio_storage_test.sh
# авто-подбор размера
#./fio_storage_test.sh /mnt/storage

# фиксированный размер 16 GiB
#./fio_storage_test.sh /mnt/storage --size 16G

# эквивалентная запись
#./fio_storage_test.sh /mnt/storage --size=8G
