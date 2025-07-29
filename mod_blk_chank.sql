CREATE OR REPLACE FUNCTION get_ctid_ranges_by_rowcount(
    p_table        regclass,   -- имя таблицы, например 'public.my_table'::regclass
    p_num_threads  integer     -- желаемое число потоков
)
RETURNS TABLE(
    thread_idx integer,  -- 0…p_num_threads−1
    tid_start   tid,     -- включительно
    tid_end     tid      -- исключительно
)
LANGUAGE plpgsql AS
$$
DECLARE
    rec RECORD;
    total_rows bigint;
    rows_per_thr numeric;
    current_thr integer := 0;
    cum_rows bigint := 0;
    start_block integer := NULL;
BEGIN
    IF p_num_threads < 1 THEN
        RAISE EXCEPTION 'p_num_threads must be >= 1';
    END IF;

    -- 1) Общее число строк
    EXECUTE format('SELECT count(*) FROM %s', p_table) INTO total_rows;

    IF total_rows = 0 THEN
        RETURN;
    END IF;

    -- 2) Целевое число строк на поток
    rows_per_thr := CEIL(total_rows::numeric / p_num_threads);

    -- 3) Для каждой страницы считаем count, сортируя по номеру блока
    FOR rec IN
      EXECUTE format(
        $f$
          SELECT (ctid).block AS blk, count(*) AS cnt
          FROM %1$s
          GROUP BY blk
          ORDER BY blk
        $f$, p_table
      )
    LOOP
        -- начало нового диапазона для потока
        IF start_block IS NULL THEN
            start_block := rec.blk;
        END IF;

        cum_rows := cum_rows + rec.cnt;

        -- как только превысили порог для current_thr
        IF cum_rows >= rows_per_thr * (current_thr + 1)
           AND current_thr < p_num_threads - 1
        THEN
            -- закрываем диапазон для current_thr
            thread_idx := current_thr;
            tid_start  := format('(%s,0)', start_block)::tid;
            -- следующий блок будет не включительно
            tid_end    := format('(%s,0)', rec.blk + 1)::tid;
            RETURN NEXT;

            -- переходим к следующему потоку
            current_thr := current_thr + 1;
            start_block := rec.blk + 1;
        END IF;
    END LOOP;

    -- 4) Наконец, закрываем последний поток вплоть до конца таблицы
    thread_idx := current_thr;
    IF start_block IS NOT NULL THEN
      -- начало последнего
      tid_start := format('(%s,0)', start_block)::tid;
      -- верхняя граница – «бесконечно далеко»
      tid_end   := '(4294967295,0)'::tid;
      RETURN NEXT;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION get_ctid_thread_batches(
    p_table         regclass,   -- имя таблицы, напр. 'public.my_table'::regclass
    p_num_threads   integer,    -- число потоков
    p_batch_size    integer     -- желаемый размер пачки (по числу строк)
)
RETURNS TABLE(
    thread_idx  integer,   -- 0…p_num_threads-1
    tid_start   tid,       -- inclusive
    tid_end     tid        -- exclusive
)
LANGUAGE plpgsql AS
$$
DECLARE
    total_rows    bigint;
    rows_per_thr  bigint;
    thr            integer;
    thr_start_off  bigint;
    thr_end_off    bigint;
    batch_start_off bigint;
    batch_end_off   bigint;
BEGIN
    IF p_num_threads < 1 OR p_batch_size < 1 THEN
        RAISE EXCEPTION 'p_num_threads and p_batch_size must be >= 1';
    END IF;

    -- 1) Узнаём общее число строк
    EXECUTE format('SELECT count(*) FROM %s', p_table) INTO total_rows;
    IF total_rows = 0 THEN RETURN; END IF;

    -- 2) Сколько строк в каждом потоке
    rows_per_thr := CEIL(total_rows::numeric / p_num_threads)::bigint;

    -- 3) Для каждого потока
    FOR thr IN 0 .. p_num_threads - 1 LOOP
        thr_start_off := thr * rows_per_thr;
        thr_end_off   := LEAST(thr_start_off + rows_per_thr - 1, total_rows - 1);

        -- если у потока нет строчек — пропускаем
        IF thr_start_off > thr_end_off THEN
            CONTINUE;
        END IF;

        -- 4) Дробим на пачки внутри потока
        batch_start_off := thr_start_off;
        WHILE batch_start_off <= thr_end_off LOOP
            batch_end_off := LEAST(batch_start_off + p_batch_size - 1, thr_end_off);

            -- получаем границы по ctid
            EXECUTE format(
              'SELECT ctid FROM %1$s ORDER BY ctid OFFSET %2$s LIMIT 1',
              p_table, batch_start_off
            ) INTO tid_start;
            IF NOT FOUND THEN
                EXIT;  -- нет больше строк
            END IF;

            IF batch_end_off + 1 < total_rows THEN
                EXECUTE format(
                  'SELECT ctid FROM %1$s ORDER BY ctid OFFSET %2$s LIMIT 1',
                  p_table, batch_end_off + 1
                ) INTO tid_end;
            ELSE
                tid_end := '(4294967295,0)'::tid;
            END IF;

            thread_idx := thr;
            RETURN NEXT;

            batch_start_off := batch_end_off + 1;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION get_ctid_thread_batches(
    p_table         regclass,   -- имя таблицы, напр. 'public.my_table'::regclass
    p_num_threads   integer,    -- число потоков
    p_batch_size    integer     -- размер пачки (по числу строк)
)
RETURNS TABLE(
    thread_idx  integer,   -- 0…p_num_threads-1
    tid_start   tid,       -- inclusive
    tid_end     tid        -- exclusive
)
LANGUAGE plpgsql AS
$$
DECLARE
    total_rows      bigint;
    rows_per_thr    bigint;
    thr             integer;
    thr_start_off   bigint;
    thr_end_off     bigint;
    batch_start_off bigint;
    batch_end_off   bigint;
BEGIN
    IF p_num_threads < 1 OR p_batch_size < 1 THEN
        RAISE EXCEPTION 'p_num_threads and p_batch_size must be >= 1';
    END IF;

    -- 1) Общее число строк
    EXECUTE format('SELECT count(*) FROM %s', p_table)
    INTO total_rows;
    IF total_rows = 0 THEN
        RETURN;  -- пустая таблица
    END IF;

    -- 2) Сколько строк приходится на каждый поток
    rows_per_thr := CEIL(total_rows::numeric / p_num_threads)::bigint;

    -- 3) Перебираем потоки
    FOR thr IN 0 .. p_num_threads - 1 LOOP
        thr_start_off := thr * rows_per_thr;
        thr_end_off   := LEAST(thr_start_off + rows_per_thr - 1, total_rows - 1);

        -- если для этого потока ничего нет — пропускаем
        IF thr_start_off > thr_end_off THEN
            CONTINUE;
        END IF;

        -- 4) Дробим поток на пачки
        batch_start_off := thr_start_off;
        WHILE batch_start_off <= thr_end_off LOOP
            batch_end_off := LEAST(batch_start_off + p_batch_size - 1, thr_end_off);

            -- находим границы по ctid:
            -- tid_start — ctid строки под OFFSET batch_start_off
            EXECUTE format(
              'SELECT ctid FROM %1$s ORDER BY id OFFSET %2$s LIMIT 1',
              p_table, batch_start_off
            ) INTO tid_start;
            -- tid_end — ctid строки под OFFSET (batch_end_off+1), либо "конец"
            IF batch_end_off < thr_end_off THEN
                EXECUTE format(
                  'SELECT ctid FROM %1$s ORDER BY id OFFSET %2$s LIMIT 1',
                  p_table, batch_end_off + 1
                ) INTO tid_end;
            ELSE
                tid_end := '(4294967295,0)'::tid;
            END IF;

            -- возвращаем одну запись диапазона
            thread_idx := thr;
            RETURN NEXT;

            -- переходим к следующей пачке
            batch_start_off := batch_end_off + 1;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION split_bigint_array(
    p_input      bigint[],
    p_batch_size integer
)
RETURNS SETOF bigint[] 
LANGUAGE plpgsql AS
$$
DECLARE
    total_len integer;
    i         integer;
    chunk     bigint[];
BEGIN
    -- Длина входного массива
    total_len := coalesce(array_length(p_input, 1), 0);
    IF total_len = 0 OR p_batch_size < 1 THEN
        RETURN;
    END IF;

    -- Бежим с шагом p_batch_size по массиву
    i := 1;
    WHILE i <= total_len LOOP
        -- Формируем подмассив от i до min(i+p_batch_size-1, total_len)
        chunk := p_input[i:LEAST(i + p_batch_size - 1, total_len)];
        RETURN NEXT chunk;
        i := i + p_batch_size;
    END LOOP;
END;
$$;
Как пользоваться
sql
Копировать
Редактировать
-- Пример: разбить большой массив на куски по 3 элемента
SELECT *
FROM split_bigint_array(ARRAY[10,20,30,40,50,60,70]::bigint[], 3);

-- Результат:
--  {10,20,30}
--  {40,50,60}
--  {70}
