#!/usr/bin/env bash
# run_progress_multi.sh
#
# Запускает набор команд (jobs.txt) параллельно, каждые из которых внутри
# вызывает вашу большую PL/pgSQL‑процедуру с update_thread_progress().
# В одном терминале рисует для каждого активного потока свой progress‑bar
# и показывает внизу «живые» логи.

#### Настройки базы и скрипта ####
DB_NAME="your_database"
DB_USER="your_user"
DB_HOST="localhost"
DB_PORT="5432"

JOBS_FILE="jobs.txt"         # Ваш список команд (по одной строке: psql … -c "SELECT my_big_proc(<id>);" )
LOG_FILE="progress.log"      # Куда писать полные логи выполнения
BAR_WIDTH=40                 # Ширина каждого бара в символах
POLL_INTERVAL=0.5            # Интервал опроса БД в секундах
TAIL_LINES=10                # Сколько последних строк логов показывать

#### Подготовка ####
: > "$LOG_FILE"               # Очистить файл логов

#### Функция рисует все прогресс‑бары ####
draw_bars(){
  # Получаем из БД список "thread_id|progress_pct|step_name"
  mapfile -t lines < <(
    psql -At -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" \
      -c "SELECT thread_id||'|'||progress_pct::text||'|'||step_name
            FROM thread_progress
           ORDER BY thread_id;"
  )

  # Заголовок таблицы баров
  printf "  %-7s %-${BAR_WIDTH}s %3s  %s\n" "Thread" "Progress" "%" "Step"

  # Для каждого потока — своя строка‑бар
  for ln in "${lines[@]}"; do
    IFS='|' read -r id pct step <<<"$ln"
    # Считаем, сколько символов заполнить и сколько пустых
    filled=$(( BAR_WIDTH * pct / 100 ))
    empty=$(( BAR_WIDTH - filled ))
    bar="$(printf '%0.s#' $(seq 1 $filled))"
    bar+=$(printf '%0.s.' $(seq 1 $empty))
    printf "  %-7s [%-${BAR_WIDTH}s] %3d%%  %s\n" \
           "$id" "$bar" "$pct" "$step"
  done
}

#### Запуск всех команд в фоне ####
pids=()
while IFS= read -r cmd || [ -n "$cmd" ]; do
  # каждая строка — полная bash‑команда, например:
  #   psql -U user -d db -c "SELECT my_big_proc(42);"
  bash -c "$cmd" >>"$LOG_FILE" 2>&1 &
  pids+=($!)
done < "$JOBS_FILE"

#### Основной цикл: перерисовываем всё в одном терминале ####
while :; do
  clear
  draw_bars
  echo
  echo "─── Логи (последние $TAIL_LINES строк) ─────────────────────────────"
  tail -n "$TAIL_LINES" "$LOG_FILE"

  # Проверяем, остались ли записи в thread_progress
  remaining=$(psql -At -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" \
                 -c "SELECT count(*) FROM thread_progress;")
  (( remaining == 0 )) && break


  sleep "$POLL_INTERVAL"
done

echo -e "\n✅ Все потоки завершены. Полные логи: $LOG_FILE"


# Как использовать:

# В файле jobs.txt перечислите ваши команды по одной на строку, например:

# psql -U your_user -d your_database -c "SELECT my_big_proc(1);"
# psql -U your_user -d your_database -c "SELECT my_big_proc(2);"
# Убедитесь, что ваши процедуры внутри вызывают update_thread_progress(thread_id, pct, step_name).

# Сделайте скрипт исполняемым и запустите:

# chmod +x run_progress_multi.sh
# ./run_progress_multi.sh
# В одном терминале вы увидите динамические прогресс‑бары сверху (по числу активных потоков) и внизу — постоянно обновляемые логи.
