#!/bin/bash

# --- Скрипт установки для Modular Dashboard for XFCE ---

set -e # Прекратить выполнение при ошибке

# --- Переменные ---
# URL вашего репозитория на GitHub (ЗАМЕНИТЕ %%USER%% и %%REPO%%)
GITHUB_USER="%%USER%%"
GITHUB_REPO="%%REPO%%"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/dashboard-plugin"

# Директория для установки
INSTALL_DIR="$HOME/.local/share/dashboard-plugin"
# Файлы для загрузки
FILES=("dashboard.sh" "dashboard.json")

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- Начало установки Modular Dashboard для XFCE ---${NC}"

# --- Проверка зависимостей ---
echo "1. Проверка необходимых утилит..."
for cmd in jq curl notify-send; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${YELLOW}Предупреждение: Утилита '$cmd' не найдена. Она необходима для полной функциональности.${NC}"
        echo "Пожалуйста, установите ее с помощью вашего пакетного менеджера (например, 'sudo apt install $cmd')."
    fi
done

# --- Установка ---
echo "2. Создание директории установки..."
mkdir -p "$INSTALL_DIR"
echo "   Директория: $INSTALL_DIR"

echo "3. Загрузка файлов скрипта..."
for file in "${FILES[@]}"; do
    echo "   - Загрузка $file..."
    if ! curl -sSL "${BASE_URL}/${file}" -o "${INSTALL_DIR}/${file}"; then
        echo -e "${YELLOW}Ошибка: Не удалось загрузить ${file} из репозитория. Проверьте URL и наличие файла в репозитории.${NC}"
        exit 1
    fi
done

echo "4. Предоставление прав на выполнение..."
chmod +x "${INSTALL_DIR}/dashboard.sh"
echo "   Права для dashboard.sh установлены."

# --- Завершение ---
echo -e "
${GREEN}--- Установка успешно завершена! ---${NC}"
echo
echo "ЧТО ДЕЛАТЬ ДАЛЬШЕ:"
echo "1. Добавьте плагин 'Generic Monitor' ('Общий монитор') на вашу панель XFCE."
echo "2. В свойствах плагина укажите следующую команду:"
echo -e "   ${YELLOW}${INSTALL_DIR}/dashboard.sh${NC}"
echo "3. Установите интервал обновления (например, 3 секунды)."
echo "4. Убедитесь, что метка ('Label') отключена."
echo
echo "Для корректной работы виджетов температуры и логов, убедитесь что:"
echo " - Установлен и настроен 'lm-sensors'."
echo " - Ваш пользователь имеет права на чтение '/var/log/auth.log' (обычно входит в группу 'adm')."
echo
echo "Вы можете настроить виджеты, редактируя файл: ${INSTALL_DIR}/dashboard.json"
echo
exit 0
