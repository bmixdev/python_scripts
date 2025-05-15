import os
from pathlib import Path

def get_largest_files(root_path, num_files=10):
    # Список для хранения информации о файлах
    files = []
    
    try:
        # Обход всех файлов в директории
        for entry in Path(root_path).rglob('*'):
            if entry.is_file():  # Проверяем, что это файл
                try:
                    size = entry.stat().st_size  # Получаем размер файла
                    files.append((entry.name, str(entry), size))
                except (PermissionError, FileNotFoundError):
                    continue  # Пропускаем файлы, к которым нет доступа
    except Exception as e:
        print(f"Ошибка при сканировании директории: {e}")
        return
    
    # Сортировка по размеру в порядке убывания
    files.sort(key=lambda x: x[2], reverse=True)
    
    # Вывод заданного количества крупнейших файлов
    print(f"\nСамые большие файлы (топ {num_files}):")
    for name, path, size in files[:num_files]:
        size_mb = size / (1024 * 1024)  # Перевод в мегабайты
        print(f"{name} ({path}): {size_mb:.2f} MB")

if __name__ == "__main__":
    # Укажите путь к диску или директории (например, 'C:/' или '/home')
    root_path = input("Введите путь к диску или директории: ")
    get_largest_files(root_path)
