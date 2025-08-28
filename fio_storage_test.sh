#сделал 💪 — скрипт принимает путь к каталогу, гоняет однопоточные и 4-поточные профили, выводит результаты и на экран, и в лог-файл (в каталоге теста). Временный тестовый файл удаляется, job-файл и логи остаются.

#!/bin/bash
# fio_storage_test.sh
# Использование: ./fio_storage_test.sh /mnt/storage

set -euo pipefail

if ! command -v fio >/dev/null 2>&1; then
  echo "fio не найден. Установи: sudo apt-get update && sudo apt-get install -y fio"
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "Использование: $0 <каталог для теста>"
  exit 1
fi

TARGET_DIR="$1"
if [ ! -d "$TARGET_DIR" ]; then
  echo "Каталог не существует: $TARGET_DIR"
  exit 1
fi
if [ ! -w "$TARGET_DIR" ]; then
  echo "Нет прав на запись в каталог: $TARGET_DIR"
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
TEST_FILE="$TARGET_DIR/fio_testfile"
JOB_FILE="$TARGET_DIR/fio_job_${TS}.fio"
LOG_FILE="$TARGET_DIR/fio_results_${TS}.log"

# Авто-очистка тестового файла при выходе
cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT

# Параметры по умолчанию (можно подправить)
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
echo "Время на профиль: ${RUNTIME} c" | tee -a "$LOG_FILE"
echo "Начало: $(date '+%F %T')" | tee -a "$LOG_FILE"
echo "----------------------------------------" | tee -a "$LOG_FILE"

# Запуск fio: вывод и на экран, и в лог
fio "$JOB_FILE" | tee -a "$LOG_FILE"

echo "----------------------------------------" | tee -a "$LOG_FILE"
echo "Готово. Временные данные удалены, результаты в: $LOG_FILE" | tee -a "$LOG_FILE"
echo "Job-файл сохранён: $JOB_FILE" | tee -a "$LOG_FILE"


#как запускать:

#chmod +x fio_storage_test.sh
#./fio_storage_test.sh /mnt/storage
