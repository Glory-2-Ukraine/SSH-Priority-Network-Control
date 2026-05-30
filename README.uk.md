# Пріоритет SSH у мережі

Забезпечує абсолютний найвищий пріоритет SSH трафіку над усім іншим мережевим трафіком на Linux. Коли сервер під великим навантаженням, SSH залишається чуйним — саме тоді, коли це найбільш потрібно.

Протестовано на Ubuntu 24 з ядром 6.8.0-111-generic, інтерфейс ens3 (QEMU/KVM віртуальна машина).

---

## Що це робить

Використовує Linux `tc` (Traffic Control — керування трафіком) для створення трьох пріоритетних смуг на мережевому інтерфейсі:

- **Смуга 1:1** — Найвищий пріоритет → SSH трафік іде сюди
- **Смуга 1:2** — Звичайний пріоритет → більшість трафіку потрапляє сюди за замовчуванням
- **Смуга 1:3** — Найнижчий пріоритет

Ядро повністю спустошує смугу 1:1 перш ніж торкатись 1:2 або 1:3. SSH продовжує працювати навіть під великим мережевим навантаженням.

IPv4 обробляється фільтрами `tc u32` що безпосередньо відповідають TCP порту 22.
IPv6 обробляється через маркування пакетів `ip6tables` разом з фільтром `tc fw` (необхідно на ядрі 6.8+).

---

## Вимоги

- Linux з встановленим `iproute2` (команда `tc`)
- Доступ root / sudo
- `ip6tables` для підтримки IPv6
- systemd для збереження після перезавантаження

Знайдіть назву вашого інтерфейсу:
```bash
ip -br link show
```
Замініть `ens3` скрізь на вашу реальну назву інтерфейсу якщо вона інша.

---

## Швидке застосування (набирає чинності негайно)

```bash
# Очистити будь-які існуючі правила
sudo tc qdisc del dev ens3 root 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true

# Створити пріоритетний qdisc зі стандартним priomap
sudo tc qdisc replace dev ens3 root handle 1: prio

# IPv4: вихідний SSH до смуги найвищого пріоритету
sudo tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp dst 22 0xffff \
  flowid 1:1

# IPv4: вхідні SSH відповіді до смуги найвищого пріоритету
sudo tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 \
  match ip protocol 6 0xff \
  match tcp src 22 0xffff \
  flowid 1:1

# IPv6: маркування SSH пакетів через ip6tables
sudo ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1

# IPv6: маршрутизація помічених пакетів до смуги найвищого пріоритету
sudo tc filter add dev ens3 parent 1:0 prio 2 handle 1 fw flowid 1:1
```

---

## Збереження після перезавантаження (systemd сервіс)

Правила tc зникають після перезавантаження. Цей сервіс автоматично відновлює все при запуску системи.

```bash
sudo tee /etc/systemd/system/ssh-qos.service > /dev/null <<EOF
[Unit]
Description=SSH QoS Priority
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  tc qdisc del dev ens3 root 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true; \
  tc qdisc replace dev ens3 root handle 1: prio && \
  tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp dst 22 0xffff flowid 1:1 && \
  tc filter add dev ens3 protocol ip parent 1:0 prio 1 u32 match ip protocol 6 0xff match tcp src 22 0xffff flowid 1:1 && \
  ip6tables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 && \
  ip6tables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 && \
  tc filter add dev ens3 parent 1:0 prio 2 handle 1 fw flowid 1:1'
ExecStop=/bin/bash -c '\
  tc qdisc del dev ens3 root; \
  ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1; \
  ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ssh-qos.service
```

---

## Перевірка що все працює

```bash
# Перевірити qdisc та фільтри
sudo tc qdisc show dev ens3
sudo tc filter show dev ens3

# Перевірити ip6tables мітки
sudo ip6tables -t mangle -L OUTPUT -v --line-numbers

# Перевірити статус сервісу
sudo systemctl status ssh-qos.service
```

Очікуваний вивід від `tc filter show dev ens3`:
```
filter parent 1: protocol ip pref 1 u32 chain 0
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::800 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00000016/0000ffff at nexthdr+0
filter parent 1: protocol ip pref 1 u32 chain 0 fh 800::801 ... *flowid 1:1
  match 00060000/00ff0000 at 8
  match 00160000/ffff0000 at nexthdr+0
filter parent 1: protocol all pref 2 fw chain 0 handle 0x1 classid 1:1
```

Очікуваний вивід від `systemctl status`: `active (exited) status=0/SUCCESS`

---

## Видалення всього

```bash
sudo systemctl disable --now ssh-qos.service
sudo tc qdisc del dev ens3 root
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
```

---

## Усунення несправностей

### Помилка "Filter already exists"
Правила з попереднього запуску ще активні. Спочатку очистіть:
```bash
sudo tc qdisc del dev ens3 root 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 1 2>/dev/null || true
sudo ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 1 2>/dev/null || true
```
Потім повторно запустіть блок застосування.

### "Filter with specified priority/protocol not found" після останньої команди
Це оманлива помилка старих версій iproute2. Вона з'являється після додавання останнього фільтра тому що tc намагається зробити підтверджуючий пошук і нічого не знаходить для порівняння. Запустіть команди перевірки — якщо фільтри відображаються, все спрацювало.

### IPv6 фільтри не працюють на ядрі 6.8+
Фільтри tc u32 IPv6 не підтримуються на ядрі 6.8.0-111-generic. Використовуйте підхід з мітками ip6tables наданий в цьому репозиторії. Не намагайтесь використовувати фільтри u32 з `protocol ipv6` на цьому ядрі.

### Сервіс не запускається
Перевірте журнал:
```bash
sudo journalctl -xeu ssh-qos.service | tail -30
```
Найімовірніша причина — залишкові правила від ручного застосування. ExecStart сервісу спочатку очищає все з `|| true` тому це має оброблятись автоматично.

### Неправильна назва інтерфейсу
Знайдіть свою за допомогою:
```bash
ip -br link show
```
Замініть кожне входження `ens3` в командах та файлі сервісу на вашу назву інтерфейсу.

### Сервіс запускається занадто рано після перезавантаження
Переконайтесь що сервіс використовує `network-online.target`, а не `network.target`. На віртуальних машинах (QEMU/KVM, MAC префікс 52:54:00) `network.target` не гарантує що інтерфейс вже налаштований.

---

## Технічні примітки

### Чому стандартний priomap правильний
Стандартний priomap qdisc prio: `1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1`. Більшість звичайного трафіку потрапляє до смуг 1:2 та 1:3. Фільтри SSH явно направляють порт 22 в 1:1. Встановлення всіх значень priomap в 0 — поширена помилка яка ставить все в 1:1, тому SSH не отримує жодної реальної переваги.

### Чому `match tcp dst`, а не `match ip dport`
Селектор `tcp` в tc u32 використовує `dst`/`src` для портів. Ключові слова `dport`/`sport` належать селектору `ip`. Використання неправильного ключового слова призводить до того що tc мовчки відхиляє фільтр з незрозумілою помилкою.

### Чому ip6tables для IPv6
На ядрі 6.8.0-111-generic фільтри tc u32 IPv6 з селектором ip6 не працюють. Підхід з мітками ip6tables є надійним обхідним рішенням: ip6tables мітить відповідні пакети значенням fwmark 1, а фільтр tc fw на prio 2 перехоплює все з цією міткою і направляє в смугу 1:1.

### Чому `network-online.target`
Цей сервер працює на QEMU/KVM (MAC префікс 52:54:00). На віртуальних машинах `network.target` не гарантує що конкретні інтерфейси як ens3 вже повністю налаштовані. `network-online.target` чекає поки хоча б один інтерфейс буде повністю онлайн перш ніж сервіс запуститься.

### Чому сервіс очищає перед застосуванням
`tc filter add` завершується з помилкою якщо відповідний фільтр вже існує. Попереднє очищення з `2>/dev/null || true` робить сервіс повністю ідемпотентним — безпечним для запуску, зупинки та перезапуску будь-яку кількість разів.

---

## Файли в цьому репозиторії

| Файл | Опис |
|------|------|
| `README.md` | Повний посібник з налаштування (англійська) |
| `README.uk.md` | Повний посібник з налаштування (українська) |
| `apply-ssh-qos.sh` | Одноразовий скрипт для негайного застосування всіх правил |
| `ssh-qos.service` | Файл systemd сервісу |
| `ssh-qos-configuration.docx` | Повний технічний документ (англійська) |
| `ssh-qos-configuration.uk.docx` | Повний технічний документ (українська) |

---

## Протестовано на

- Ubuntu 24, ядро 6.8.0-111-generic
- Інтерфейс: ens3 (QEMU/KVM віртуальний NIC, MAC 52:54:00:*)
- iproute2 6.1.0
- 8-ядерний сервер
