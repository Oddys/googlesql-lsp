# A script for testing
send() {
  printf 'Content-Length: %d\r\n\r\n%s' "$(printf %s "$1" | wc -c | tr -d ' ')" "$1"
}

URI='hello.sql'

send '{"jsonrpc":"2.0","id":101,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
send '{"jsonrpc":"2.0","method":"initialized","params":{}}'

send '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"SQL","version":1,"text":"SELECT 1;"}}}'

send '{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"'"$URI"'"}}}'

send '{"jsonrpc":"2.0","id":102,"method":"shutdown"}'
send '{"jsonrpc":"2.0","method":"exit"}'
