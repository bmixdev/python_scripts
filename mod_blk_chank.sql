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
