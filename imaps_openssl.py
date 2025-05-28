import subprocess
import base64
import time
from ntlm_auth.ntlm import NtlmContext

# === Настройки подключения ===
HOST = "imap.example.com"
PORT = 993
USERNAME = "DOMAIN\\username"
PASSWORD = "your_password"

# === Подготовка NTLM-контекста ===
ctx = NtlmContext(USERNAME, PASSWORD)

# === Открываем openssl IMAPS соединение ===
proc = subprocess.Popen(
    ["openssl", "s_client", "-crlf", "-quiet", "-connect", f"{HOST}:{PORT}"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1
)

def send(cmd):
    print(f">>> {cmd.strip()}")
    proc.stdin.write(cmd + "\n")
    proc.stdin.flush()

def recv_line():
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        print(f"<<< {line.strip()}")
        if line.startswith('+'):
            return line.strip()
        if line.startswith('a1 OK') or 'BAD' in line or 'NO' in line:
            return line.strip()

# === Шаг 1: инициируем AUTH NTLM ===
send("a1 AUTHENTICATE NTLM")
recv_line()  # ждем "+"

# === Шаг 2: Type 1 сообщение ===
type1 = base64.b64encode(ctx.step()).decode()
send(type1)

# === Шаг 3: сервер прислал challenge (Type 2) ===
line = recv_line()
if not line.startswith("+ "):
    print("❌ Сервер не прислал challenge")
    exit(1)

challenge_b64 = line[2:]
challenge = base64.b64decode(challenge_b64)

# === Шаг 4: Type 3 ответ ===
type3 = base64.b64encode(ctx.step(challenge)).decode()
send(type3)

# === Шаг 5: финальный ответ сервера ===
final = recv_line()
if "OK" in final:
    print("✅ Успешная аутентификация!")
else:
    print("❌ Ошибка при аутентификации:", final)

# === Закрыть соединение ===
send("a2 LOGOUT")
time.sleep(1)
proc.terminate()
