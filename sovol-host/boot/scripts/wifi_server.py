from flask import Flask, request, jsonify
import subprocess

app = Flask(__name__)

@app.route('/scan_wifi', methods=['GET'])
# def scan_wifi():
#     result = subprocess.getoutput("nmcli -t -f SSID device wifi list")
#     wifi_list = list(set(filter(None, result.split('\n'))))
#     return jsonify(wifi_list)

def scan_wifi():
    # 获取 SSID、信号强度、加密方式
    result = subprocess.getoutput("nmcli -t -f SSID,SIGNAL,SECURITY device wifi list")
    wifi_list = []
    for line in result.strip().split('\n'):
        if line:
            parts = line.split(':')
            if len(parts) >= 3:
                ssid = parts[0] or "<隐藏网络>"
                signal = parts[1]
                security = parts[2]
                wifi_list.append({
                    "ssid": ssid,
                    "signal": int(signal),
                    "security": security
                })

    # 按信号强度从高到底排序
    wifi_list.sort(key=lambda x: x['signal'], reverse=True)
    return jsonify(wifi_list)

@app.route('/connect_wifi', methods=['POST'])
def connect_wifi():
    data = request.json
    ssid = data.get('ssid')
    password = data.get('password')
    cmd = f"nmcli device wifi connect '{ssid}' password '{password}'"
    result = subprocess.getoutput(cmd)
    return jsonify({'result': result})

@app.route('/get_ip', methods=['GET'])
def get_ip():
    try:
        result = subprocess.getoutput("ip -4 addr show wlan0 | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'")
        ip_address = result.strip()
        if ip_address:
            return jsonify({'ip': ip_address})
        else:
            return jsonify({'error': 'No IP found on wlan0'}), 404
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)

