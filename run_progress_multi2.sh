#!/usr/bin/env bash
# run_progress_multi.sh
# Параллельно запускает команды из jobs.txt, рисует сверху динамические прогресс‑бары
# (число баров = активные записи в thread_progress), а логи идут внизу и скроллятся.

#### 1. Конфигурация ####
DB_NAME="your_database"
DB_USER="your_user"
DB_HOST="localhost"
DB_PORT="5432"

JOBS_FILE="jobs.txt"         # по одной psql-команде на строку
LOG_FILE="progress.log"      # общий лог (stdout/stderr)
BAR_WIDTH=40                 # ширина каждого бара
POLL_INTERVAL=0.5            # секунда между обновлениями экрана

#### 2. Подготовка ####
: >"$LOG_FILE"               # очистить лог
clear

# Получаем общее число строк терминала
LINES_TOTAL=$(tput lines)
HEADER_LINES=1               # строка заголовка (Thread Progress% Step)

#### 3. Tail логов в скролл‑регионе ####
# Изначально reserved_lines = HEADER_LINES (пока нет баров)
reserved_lines=$HEADER_LINES
# Задаём scroll region: HEADER_LINES..(LINES_TOTAL-1)
tput csr "$reserved_lines" $(( LINES_TOTAL - 1 ))
# Запускаем tail -F, он будет выводиться в этой области
tail -n0 -F "$LOG_FILE" &> /dev/tty &
TAIL_PID=$!

#### 4. Функция отрисовки прогресс‑баров ####
draw_bars(){
  mapfile -t lines < <(
    psql -At -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" \
      -c "SELECT thread_id||'|'||progress_pct||'|'||step_name
            FROM thread_progress
           ORDER BY thread_id;"
  )

  # Заголовок
  printf "  %-7s %-${BAR_WIDTH}s %3s  %s\n" \
         "Thread" "Progress" "%" "Step"

  # Сами бары
  for ln in "${lines[@]}"; do
    IFS='|' read -r tid pct step <<<"$ln"
    filled=$(( BAR_WIDTH * pct / 100 ))
    empty=$(( BAR_WIDTH - filled ))
    bar="$(printf '%0.s#' $(seq 1 $filled))"
    bar+=$(printf '%0.s.' $(seq 1 $empty))
    printf "  %-7s [%-${BAR_WIDTH}s] %3d%%  %s\n" \
           "$tid" "$bar" "$pct" "$step"
  done
}

#### 5. Запуск задач в фоне ####
while IFS= read -r cmd || [ -n "$cmd" ]; do
  # каждая строка — например:
  #   psql -U user -d db -c "SELECT do_work(42);"
  bash -c "$cmd" >>"$LOG_FILE" 2>&1 &
done < "$JOBS_FILE"

#### 6. Основной цикл перерисовки ####
while :; do
  # Сколько сейчас активных потоков
  threads=$(psql -At -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" \
                 -c "SELECT count(*) FROM thread_progress;")

  # Пересчитаем reserved_lines (header + количество баров)
  reserved_lines=$(( HEADER_LINES + threads ))

  # Обновляем scroll region
  tput csr "$reserved_lines" $(( LINES_TOTAL - 1 ))

  # Очищаем зарезервированную область: строки 0..reserved_lines-1
  for (( i=0; i<reserved_lines; i++ )); do
    tput cup "$i" 0
    tput el
  done

  # Рисуем бары
  tput cup 0 0
  draw_bars

  # Если потоков не осталось — выход
  (( threads == 0 )) && break

  sleep "$POLL_INTERVAL"
done

#### 7. Завершение ####
kill "$TAIL_PID" 2>/dev/null
# Сброс scroll region на всю область
tput csr 0 $(( LINES_TOTAL - 1 ))

echo -e "\n✅ Все потоки завершены. Полный лог: $LOG_FILE"
