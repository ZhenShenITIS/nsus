#!/bin/bash

# Базовая директория для всех узлов
base_dir=/root/nexus_nodes

# Функция для проверки и установки Docker, если он не установлен
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker не установлен. Устанавливаю Docker..."
        apt-get update && apt-get install -y docker.io
    fi
}

# Функция для создания базового Docker-образа с необходимыми зависимостями для Nexus
build_base_image() {
    check_docker
    image_name="nexus-node-image"
    if ! docker images | grep -q "$image_name"; then
        echo "Создание базового Docker-образа для Nexus..."
        cat > Dockerfile.nexus <<EOF
FROM ubuntu:24.04

ENV container=docker

RUN apt-get update && \\
    apt-get upgrade -y && \\
    apt-get install -y --no-install-recommends \\
        curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev && \\
    apt-get clean && \\
    rm -rf /var/lib/apt/lists/*

VOLUME [ "/sys/fs/cgroup" ]
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
EOF
        docker build -t "$image_name" -f Dockerfile.nexus .
        rm Dockerfile.nexus
    fi
}

check_docker
build_base_image

rebuild_base_image(){
  local image_name="nexus-node-image"

  # Проверяем, существует ли образ
  image_id=$(docker images -q "$image_name")

  if [ -n "$image_id" ]; then
      echo "Образ $image_name существует. Удаляем его..."
      docker rmi -f "$image_id"
  else
      echo "Образ $image_name не найден. Создаем новый образ..."
  fi

  # Вызываем функцию для сборки образа
  build_base_image
}

# Функция для поиска свободного порта на хосте начиная с 6010
find_free_port() {
    local port=6010
    while :
    do
        if ! ss -tulpn | grep -q ":$port "; then
            echo $port
            return
        fi
        port=$((port+1))
    done
}

install_new_container() {
    local proxy_details="$1"

    echo "Установка нового узла Nexus..."

    # Парсинг данных прокси
    proxy_ip=$(echo $proxy_details | cut -d':' -f1)
    proxy_port=$(echo $proxy_details | cut -d':' -f2)
    proxy_username=$(echo $proxy_details | cut -d':' -f3)
    proxy_password=$(echo $proxy_details | cut -d':' -f4)

    # Создание корневой директории, если не существует
    mkdir -p "$base_dir"

    # Определение следующего узла
    node_num=$(ls -l $base_dir | grep -c ^d)
    node_name="nexus-node$((node_num + 1))"
    node_dir="$base_dir/$node_name"
    mkdir "$node_dir"

    # Сохранение данных прокси
    echo "HTTP_PROXY=http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port" > "$node_dir/proxy.conf"
    echo "HTTPS_PROXY=http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port" >> "$node_dir/proxy.conf"

    # Получение свободного порта на хосте
    host_port=$(find_free_port)

    # Запуск контейнера
    docker run -d --privileged \
        -e container=docker \
        -e HTTP_PROXY="http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port" \
        -e HTTPS_PROXY="http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port" \
        --memory="286m" \
        --cpus="0.5" \
        -p "$host_port:6010" \
        --name "$node_name" \
        --hostname VPS \
        nexus-node-image

    if [ $? -eq 0 ]; then
        echo "Контейнер $node_name успешно запущен на порту $host_port" | tee -a "$node_dir/$node_name.log"
    else
        echo "Ошибка при запуске контейнера $node_name"
        return 1
    fi

    # Установка Nexus внутри контейнера
    echo "Запуск контейнера $node_name..."
    docker exec "$node_name" bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      export HTTP_PROXY=\"http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port\"
      export HTTPS_PROXY=\"http://$proxy_username:$proxy_password@$proxy_ip:$proxy_port\"
      "

}

# Функция для мульти-запуска контейнеров из файла data.txt
multi_install_containers() {
    if [ ! -f data.txt ]; then
        echo "Файл data.txt не найден"
        return 1
    fi

    while IFS= read -r proxy_details; do
        # Пропускаем пустые строки
        [ -z "$proxy_details" ] && continue

        install_new_container "$proxy_details"
    done < data.txt
}

# Функция для обновления всех контейнеров
update_all_nodes() {
    echo "Обновление всех узлов Nexus..."
    for container in $(docker ps -a --filter "name=nexus-node" --format "{{.Names}}"); do
        echo "Обновление $container..."
        docker exec -it "$container" bash -c "
          set -e
          # Команды для обновления Nexus внутри контейнера
          # Например:
          # cd /root/nexus && git pull && cargo build --release
          # systemctl restart nexus

          # Заглушка для реальных команд обновления
        "
    done
    echo "Все узлы успешно обновлены."
}

# Функция для перезапуска всех узлов
restart_all_nodes() {
    echo "Перезапуск всех узлов Nexus..."
    for container in $(docker ps -a --filter "name=nexus-node" --format "{{.Names}}"); do
        echo "Перезапуск $container..."
        docker exec "$container" systemctl restart nexus
    done
    echo "Все узлы успешно перезапущены."
}

show_header() {
  echo ""
  echo ""
  echo ""
  echo ""
}

show_menu(){
  echo "Выберите действие:"
  echo "1. Пересоздать Docker-образ"
  echo "2. Создать контейнер с программой Nexus"
  echo "3. Обновить все контейнеры (НЕ РАБОТАЕТ)"
  echo "4. Перезапустить все контейнеры"
  echo "5. Мульти-запуск контейнеров из data.txt"
  echo "0. Выход"
  echo -n "Введите номер действия: "
}

# Основной цикл меню
main_menu() {
    while true; do
        show_header
        show_menu
        read action
        case $action in
                1)
                    rebuild_base_image
                    ;;
                2)
                    echo "Введите данные прокси (IP:Port:Login:Pass): "
                    read proxy_details
                    install_new_container "$proxy_details"
                    ;;
                3)
                    update_all_nodes
                    ;;
                4)
                    restart_all_nodes
                    ;;
                5)
                    multi_install_containers
                    ;;
                0)
                    echo "Скрипт завершён."
                    exit 0
                    ;;
                *)
                    echo "Неверный выбор. Попробуйте снова."
                    ;;
        esac
    done
}

# Запуск основного меню
main_menu
