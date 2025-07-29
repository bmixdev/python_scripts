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
