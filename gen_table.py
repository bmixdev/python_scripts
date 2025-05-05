#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import sys
from html import escape

def generate_html(process_list, output_path):
    """
    Генерирует HTML-файл с таблицей из списка процессов.
    
    :param process_list: список словарей с процессами
    :param output_path: путь до выходного HTML-файла
    """
    # Шапка HTML
    html_head = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Состояние процессов</title>
    <style>
        table { 
            border-collapse: collapse; 
            width: 100%;
        }
        th, td { 
            border: 1px solid #ccc; 
            padding: 8px; 
            text-align: left;
            vertical-align: top;
        }
        th {
            background: #f0f0f0;
        }
        .details {
            background: #fafafa;
            font-family: monospace;
            white-space: pre-wrap;
        }
    </style>
</head>
<body>
    <h1>Состояние процессов</h1>
    <table>
        <thead>
            <tr>
                <th>PID</th>
                <th>Client Addr</th>
                <th>Backend Start</th>
                <th>State</th>
                <th>Hold Duration</th>
            </tr>
        </thead>
        <tbody>
"""

    # Футер HTML
    html_tail = """        </tbody>
    </table>
</body>
</html>
"""

    # Собираем строки таблицы
    rows = []
    for proc in process_list:
        pid             = escape(str(proc.get("pid", "")))
        client_addr     = escape(proc.get("client_addr", ""))
        backend_start   = escape(proc.get("backend_start", ""))
        state           = escape(proc.get("state", ""))
        hold_duration   = escape(str(proc.get("hold_duration", "")))
        query           = escape(proc.get("query", ""))
        
        # viewQueue может быть списком словарей или одним словарем
        vq = proc.get("viewQueue", [])
        if isinstance(vq, dict):
            vq = [vq]
        
        # Если несколько записей в viewQueue, объединим их
        details_lines = []
        for item in vq:
            tn = escape(item.get("ThreadName", ""))
            ts = escape(item.get("threadStack", ""))
            details_lines.append(f"ThreadName: {tn}\nThreadStack: {ts}")
        details_text = f"Query: {query}\n\n" + "\n\n".join(details_lines)

        # Первая строка с основными полями
        row_main = f"""            <tr>
                <td>{pid}</td>
                <td>{client_addr}</td>
                <td>{backend_start}</td>
                <td>{state}</td>
                <td>{hold_duration}</td>
            </tr>"""
        # Вторая строка с деталями
        row_details = f"""            <tr>
                <td class="details" colspan="5">{details_text}</td>
            </tr>"""

        rows.append(row_main)
        rows.append(row_details)

    # Записываем файл
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html_head)
        f.write("\n".join(rows))
        f.write(html_tail)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Использование: python3 gen_table.py input.json output.html")
        sys.exit(1)

    input_file  = sys.argv[1]
    output_file = sys.argv[2]

    # Читаем JSON
    with open(input_file, "r", encoding="utf-8") as f:
        data = json.load(f)

    generate_html(data, output_file)
    print(f"HTML-страница успешно сохранена в {output_file}")
