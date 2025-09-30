#!/bin/bash

# Easy VK Tunnel v2.0

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_FILE="/tmp/easy-vk-tunnel.log"

VK_TUNNEL_CMD=$(command -v vk-tunnel || echo "/usr/local/bin/vk-tunnel")
CURL_CMD=$(command -v curl || echo "/usr/bin/curl")
PGREP_CMD=$(command -v pgrep || echo "/usr/bin/pgrep")
PKILL_CMD=$(command -v pkill || echo "/usr/bin/pkill")

# логи
log() {
	echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
	echo "$1"
}

##########################################
#Настройки
UUID="" #UUID ws inbound
INBOUNDPORT="" #Порт inbound
WSPATH="/" #Путь ws
ZONE_ID="" #Зона из CF
CLOUDFLARE_EMAIL=""
CLOUDFLARE_API_KEY=""
GLOBAL_DOMAIN="" #Домен привязанный к CF
COMMENTVE="Tunnel"
##########################################

# urlencode
urlencode() {
	local string="$1"
	local length="${#string}"
	local encoded=""
	local i char

	for ((i = 0; i < length; i++)); do
		char="${string:i:1}"
		case "$char" in
			[a-zA-Z0-9.~_-]) encoded+="$char" ;;
			*) encoded+=$(printf '%%%02X' "'$char") ;;
		esac
	done
	echo "$encoded"
}


# проверка наличия необходимых команд
check_commands() {
	local commands=("curl" "pgrep" "pkill")
	local missing=()
	
	for cmd in "${commands[@]}"; do
		if ! command -v "$cmd" &> /dev/null; then
			missing+=("$cmd")
		fi
	done
	
	if [[ ${#missing[@]} -gt 0 ]]; then
		log "Отсутствуют команды: ${missing[*]}"
		return 1
	fi
	
	return 0
}

# чекер работоспособности туннеля
check_tunnel() {
	local domain="$1"
	local url="https://${domain}${WSPATH}"
	local response
	local exit_code
	local attempt
	
	for attempt in {1..3}; do 
		log "Проверка туннеля $domain (попытка $attempt/3)..."
		
		response=$($CURL_CMD -sk \
			--connect-timeout 5 \
			--max-time 8 \
			--retry 2 \
			--retry-delay 1 \
			--retry-max-time 10 \
			"$url" 2>/dev/null)
		exit_code=$?
		
		if [[ $exit_code -eq 0 ]]; then
			if echo "$response" | grep -q "Bad Request"; then
				log "Туннель корректно отвечает ($domain)"
				return 0
			else
				log "Проблема с туннелем ($domain). Неверный ответ. Ответ: $response"
				
				if echo "$response" | grep -q "there is no tunnel connection associated with given host"; then
					log "Туннель не ассоциирован с доменом."
					return 1
				fi
			fi
		else
			log "Ошибка проверки туннеля (curl exit code: $exit_code) - попытка $attempt/3"
			
			if [[ $exit_code -eq 28 && $attempt -lt 3 ]]; then
				sleep 2
			fi
		fi
		
		if [[ $attempt -lt 3 ]]; then
			sleep 2
		fi
	done
	
	log "Все попытки проверки туннеля $domain завершились неудачно"
	return 1
}

# запускаем туннель
start_vk_tunnel() {
	log "Запуск vk-tunnel на порту $INBOUNDPORT..."
	
	# Получаем все PID процессов vk-tunnel с указанным портом
	local pids=($($PGREP_CMD -f "vk-tunnel --port=$INBOUNDPORT"))
	
	# Если найдены процессы, убиваем их все
	if [[ ${#pids[@]} -gt 0 ]]; then
		log "Найдено процессов vk-tunnel: ${#pids[@]}"
		log "PID процессов: ${pids[*]}"
		
		for pid in "${pids[@]}"; do
			log "Убиваем процесс vk-tunnel с PID: $pid"
			kill -9 "$pid" 2>/dev/null
		done
		
		# Дополнительная проверка и принудительное убийство через pkill
		$PKILL_CMD -f "vk-tunnel --port=$INBOUNDPORT" 2>/dev/null
		
		sleep 2
		
		# Проверяем, что все процессы убиты
		local remaining_pids=($($PGREP_CMD -f "vk-tunnel --port=$INBOUNDPORT"))
		if [[ ${#remaining_pids[@]} -gt 0 ]]; then
			log "Предупреждение: остались процессы после убийства: ${remaining_pids[*]}"
		else
			log "Все процессы vk-tunnel успешно убиты"
		fi
	else
		log "Активных процессов vk-tunnel не найдено"
	fi
	
	# Запускаем новый процесс
	$VK_TUNNEL_CMD --port=$INBOUNDPORT > /tmp/vk-tunnel.log 2>&1 &
	
	# цикл проверки домена
	log "Ожидание появления домена в логах..."
	local domain=""
	
	for ((i=1; i<=30; i++)); do
		sleep 1
		domain=$(get_current_domain)
		if [[ -n "$domain" ]]; then
			log "Домен найден: $domain (попытка $i/30)"
			break
		fi
		log "Домен еще не появился в логах... (попытка $i/30)"
	done
	
	if [[ -z "$domain" ]]; then
		log "Ошибка: домен не найден в логах после 30 секунд ожидания"
		return 1
	fi
	
	local vk_pids=($($PGREP_CMD -f "vk-tunnel --port=$INBOUNDPORT"))
	if [[ ${#vk_pids[@]} -eq 0 ]]; then
		log "Ошибка: vk-tunnel не запустился"
		return 1
	elif [[ ${#vk_pids[@]} -gt 1 ]]; then
		log "Предупреждение: запущено несколько процессов vk-tunnel: ${vk_pids[*]}"
		# Оставляем только первый процесс (основной)
		for ((i=1; i<${#vk_pids[@]}; i++)); do
			log "Убиваем дополнительный процесс: ${vk_pids[i]}"
			kill -9 "${vk_pids[i]}" 2>/dev/null
		done
		vk_pid="${vk_pids[0]}"
	else
		vk_pid="${vk_pids[0]}"
	fi
	
	log "vk-tunnel запущен (PID: $vk_pid)"
	return 0
}

update_global_dns() {
	local domain="$1"

	if [[ -z "$ZONE_ID" || -z "$CLOUDFLARE_EMAIL" || -z "$CLOUDFLARE_API_KEY" ]]; then
	log "ZONE_ID, CLOUDFLARE_EMAIL, CLOUDFLARE_API_KEY не заданы"
	return 1
	fi

	log "Обновление CNAME в Cloudflare"
	response=$(curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/batch" \
	-H "Content-Type: application/json" \
	-H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
	-H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
	-d "{
		  \"name\": \"$GLOBAL_DOMAIN\",
		  \"ttl\": 60,
		  \"type\": \"CNAME\",
		  \"comment\": \"Domain verification record\",
		  \"content\": \"$domain\",
		  \"proxied\": false
		}"
	)
}

# получаем домен туннеля из вывода после запуска
get_current_domain() {
	local domain
	
	# Извлекаем домен из логов
	domain=$(grep -oE 'https://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' /tmp/vk-tunnel.log 2>/dev/null | tail -n 5 | sed 's|https://||')
	
	if [[ -z "$domain" ]]; then
		domain=$(grep -oE 'wss://[a-zA-Z0-9-]+[-a-zA-Z0-9]*\.tunnel\.vk-apps\.com' /tmp/vk-tunnel.log 2>/dev/null | tail -n 5 | sed 's|wss://||')
	fi
	
	echo "$domain"
}

# надзорный скрипт watchdog
watchdog() {
	log "Запуск watchdog-проверки"

	
	if ! check_commands; then
		log "Ошибка: не все необходимые команды доступны"
		return 1
	fi
	
	# чекаем туннель
	if check_tunnel "$LAST_DOMAIN"; then
		log "Ничего не делаем, всё хорошо"
		return 0
	fi
	
	log "Обнаружена проблема с туннелем. Перезапуск..."
	
	# рестарт туннеля
	if ! start_vk_tunnel; then
		log "Критическая ошибка: не удалось перезапустить vk-tunnel"
		return 1
	fi
	
	# смотрим на то, какой домен выдал вк
	local new_domain
	new_domain=$(get_current_domain)
	
	if [[ -z "$new_domain" ]]; then
		log "Ошибка: не удалось получить новый домен"
		return 1
	fi
	
	log "Новый домен: $new_domain"
	
	# если домен изменился, обновляем файл подписки
	if [[ "$new_domain" != "$LAST_DOMAIN" ]]; then
		log "Домен изменился. Обновление клиентского домена..."
		
		if update_global_dns "$new_domain"; then
			LAST_DOMAIN="$new_domain"
			log "Клиентский домен успешно обновлен"
		else
			log "Ошибка обновления клиентского домена"
		fi
	else
		log "Домен не изменился"
	fi
	
	log "Watchdog проверка завершена"
}

# скрипт запуска туннеля
run_tunnel() {
	local encoded_wspath=$(urlencode "$WSPATH")
	local vless_link="vless://${UUID}@${GLOBAL_DOMAIN}:443?type=ws&path=${encoded_wspath}&security=tls#${COMMENTVE}"
	
	echo "Постоянная vless ссылка"
	echo "$vless_link"
	if command -v qrencode >/dev/null 2>&1; then
		echo "$vless_link" | qrencode -t UTF8
	else
		log "⚠️ qrencode не установлен (apt install qrencode)"
	fi
	echo "Логи тут: $LOG_FILE"
	while true; do
		if [[ -z "$LAST_DOMAIN" ]]; then
			log "Домен пустой, пробую стартовать туннель..."
			start_vk_tunnel
		elif ! watchdog; then
			log "Watchdog: туннель не работает, перезапуск..."
			start_vk_tunnel
		else
			log "Watchdog: туннель живой ($LAST_DOMAIN)"
		fi
		sleep 60
	done
}
run_tunnel
