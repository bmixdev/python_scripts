#!/usr/bin/env python3
import sys
import os

ENV_FILE = "variables.env"

def load_env(filepath):
    env = {}
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, val = line.split('=', 1)
                env[key.strip()] = val.strip()
    return env

def save_env(env, filepath):
    with open(filepath, "w", encoding="utf-8") as f:
        for key, val in env.items():
            f.write(f"{key}={val}\n")

def print_usage():
    print("Usage:")
    print("  add/update : script.py set KEY VALUE")
    print("  delete     : script.py del KEY")
    print("  get        : script.py get KEY")
    print("  list all   : script.py list")
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print_usage()

    cmd = sys.argv[1]
    env = load_env(ENV_FILE)

    if cmd == "set" and len(sys.argv) == 4:
        key, value = sys.argv[2], sys.argv[3]
        env[key] = value
        save_env(env, ENV_FILE)
        print(f"✅ {key}={value} saved to {ENV_FILE}")
    elif cmd == "del" and len(sys.argv) == 3:
        key = sys.argv[2]
        if key in env:
            del env[key]
            save_env(env, ENV_FILE)
            print(f"❌ {key} removed from {ENV_FILE}")
        else:
            print(f"⚠️  {key} not found.")
    elif cmd == "get" and len(sys.argv) == 3:
        key = sys.argv[2]
        print(env.get(key, f"⚠️  {key} not found."))
    elif cmd == "list":
        if not env:
            print("📂 No variables found.")
        else:
            for k, v in env.items():
                print(f"{k}={v}")
    else:
        print_usage()

if __name__ == "__main__":
    main()
