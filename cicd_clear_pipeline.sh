#!/bin/bash

# Параметры: измените на ваши значения
GITLAB_URL="https://gitlab.example.com"      # URL вашего GitLab
PROJECT_ID="ваш_ID_проекта"                    # ID проекта
PRIVATE_TOKEN="ваш_private_token"              # Ваш персональный токен для API

# Расчёт пороговой даты: 1 день назад (в формате ISO)
DATE_THRESHOLD=$(date -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)

# Настройки пагинации
PAGE=1
PER_PAGE=100

echo "Запуск процесса удаления старых пайплайнов..."

while true; do
    echo "Обрабатывается страница $PAGE"
    RESPONSE=$(curl --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
      "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines?per_page=$PER_PAGE&page=$PAGE")

    # Если пайплайнов больше нет, выходим из цикла
    PIPELINE_COUNT=$(echo "$RESPONSE" | jq length)
    if [ "$PIPELINE_COUNT" -eq 0 ]; then
        break
    fi

    # Обрабатываем каждый пайплайн из текущей страницы
    for pipeline in $(echo "$RESPONSE" | jq -r '.[] | @base64'); do
        _jq() {
            echo ${pipeline} | base64 --decode | jq -r ${1}
        }

        PIPELINE_ID=$(_jq '.id')
        CREATED_AT=$(_jq '.created_at')

        # Сравнение даты создания с пороговой датой (преобразуем даты в секунды)
        CREATED_AT_SECONDS=$(date -d "$CREATED_AT" +%s)
        DATE_THRESHOLD_SECONDS=$(date -d "$DATE_THRESHOLD" +%s)

        if [ "$CREATED_AT_SECONDS" -lt "$DATE_THRESHOLD_SECONDS" ]; then
            # Получаем подробную информацию по пайплайну для проверки duration
            PIPELINE_DETAIL=$(curl --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
              "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID")
            DURATION=$(echo "$PIPELINE_DETAIL" | jq '.duration')

            # Проверяем, что duration не равно null и меньше 60 секунд
            if [ "$DURATION" != "null" ] && [ "$(echo "$DURATION < 60" | bc -l)" -eq 1 ]; then
                echo "Удаляется пайплайн $PIPELINE_ID (время выполнения: $DURATION сек, создан: $CREATED_AT)"
                curl --request DELETE --silent --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
                  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID"
            fi
        fi
    done

    PAGE=$((PAGE + 1))
done

echo "Удаление завершено."
