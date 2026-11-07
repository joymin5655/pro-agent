# 안전장치와 한계

pro-agent에는 위험한 셸 명령을 미리 걸러 내는 자동 점검 장치(hook)가 있습니다. 파일은 `hooks/guard-bash.sh`입니다.
이 장치는 안전망일 뿐이고, 모든 위험을 막지는 못합니다.

## 막는 것(deny)

아래 명령은 실행 전에 막습니다.

- `rm`에 재귀(`-r`)와 강제(`-f`) 옵션을 함께 주고 대상 중 하나가 루트(`/`, `/*`), 홈(`~`, `~/`, `~/*`), `$HOME`, `${HOME}`인 경우. 옵션 순서, `-r -v -f`처럼 나눈 옵션, `--recursive --force` 형태, `--` 뒤의 대상, `/bin/rm`, `sudo`·`env`·`bash -c`로 감싼 명령도 잡습니다.
- 강제 푸시: `git push --force`, `-f`(`-uf` 같은 묶음 포함), `+브랜치` 형태. `git -C 경로 push --force`처럼 git 앞쪽 옵션이 붙어도 잡습니다. `--force-with-lease`는 막지 않습니다.
- `git`과 함께 쓴 `--no-verify`
- `mkfs`(디스크 포맷)
- `dd`로 장치에 직접 쓰기(`of=/dev/...`). 단 `of=/dev/null`, `/dev/zero`, `/dev/stdout`, `/dev/stderr`, `/dev/tty`, `/dev/fd/…`처럼 디스크가 아닌 곳에 쓰는 것은 허용합니다.
- 포크 폭탄(`:(){ :|:& };:`)

## 물어보는 것(ask)

아래 명령은 실행해도 되는지 먼저 묻습니다.

- `git reset --hard`(`git -C 경로 reset --hard`처럼 앞쪽 옵션이 붙은 것 포함)
- `git clean -f`, `git clean --force` 계열(`-n`만 쓰면 묻지 않습니다)
- `curl`이나 `wget`으로 받은 내용을 바로 `sh`, `bash`, `zsh`에 넘기는 명령(`/bin/bash`, `sudo bash`처럼 경로나 sudo가 붙어도 잡습니다)
- 내려받은 내용을 파이프 없이 셸에 넘기는 명령: `bash -c "$(curl …)"`, `bash <(curl …)`, `bash <<< "$(curl …)"`, `source <(curl …)`, `. <(curl …)`, `eval "$(curl …)"` 같은 꼴입니다. Homebrew 공식 설치 명령도 이 꼴이라 실행 전에 한 번 묻습니다.
- `sudo`(뒤에 명령이 없는 `sudo -i`, `sudo -s`도 포함)

막는 것(deny)과 묻는 것(ask)에 모두 걸리면 막는 쪽이 이깁니다.

## 허용되는 예

시험(`tests/test-guard-bash.sh`)에 들어 있는 사례입니다.

- `rm -rf ./build`, `rm -rf node_modules`, `rm -rf ~/Downloads/old-folder`
- `git push`, `git push --force-with-lease`, `git push --follow-tags`
- `git reset --soft HEAD~1`
- `git commit -m "update docs"`
- `dd if=a.img of=b.img`, `dd if=/dev/zero of=/dev/null bs=1m count=10`
- `git push origin main && echo -f`, `git push --force-with-lease=main origin main`, `git clean -n`
- `rm -rf ./build ~/Downloads/old`, `echo "rm -rf ~" > notes.txt`, `git commit -m "fix: avoid rm -rf ~ in docs"`
- `dd if=/dev/zero of=/dev/null; echo done`, `ls ~ && echo done`
- `eval "$(/opt/homebrew/bin/brew shellenv)"`, `bash -c "echo hi"`, `curl -fsSL https://example.com/data.json | jq .`, `. ./env.sh`
- `git commit -m "docs: (a) b; c & d | e"`, `curl -fsSL "https://x.example/data?a=1&b=2" | jq .`, `timeout 30 npm test`, `dd if=a.img of=/dev/stdout`
- 여러 줄 명령에서도 위험한 줄이 없으면 허용합니다. 따옴표 안의 `\n`(예: `printf 'a\nb'`)도 허용합니다.

## 동작 방식

1. 도구 호출 이벤트에서 실행할 명령(`command` 칸)만 꺼냅니다. 설명(description) 칸의 글자는 보지 않습니다. 명령 칸을 못 찾으면 이벤트 전체를 대신 검사합니다.
2. 이벤트 안의 이스케이프(`\n`, `\r`, `\t`, `\\`, `\"`)를 풉니다. 줄 끝의 역슬래시(홀수 개)는 셸처럼 줄 이어쓰기로 보고 다음 줄과 합치며, 그 밖의 줄바꿈은 명령 경계로 바꿉니다. 따옴표로 묶었거나 `\ `로 이스케이프한 값은 한 덩어리로 묶어 두었다가 옵션 값을 건너뛸 때만 한 낱말로 씁니다(위험 판정은 늘 다시 나눈 낱말로 합니다). 그다음 남은 역슬래시와 따옴표를 모두 지웁니다. `r''m`이나 `r\m` 같은 우회를 막기 위해서입니다. `${HOME}`은 `$HOME`으로 맞춥니다.
3. 명령을 두 가지로 나눠 둘 다 판정합니다. ① `;`, `&&`, `||`, `&`, 괄호, 중괄호, 백틱, 줄바꿈에서 따옴표 안까지 모두 나눕니다. `bash -c '…'`처럼 문자열 안에 든 명령도 보기 위해서입니다. ② 따옴표와 `$(…)` 안의 기호는 그대로 두고 바깥의 명령 경계에서만 나눕니다. 따옴표 안에 괄호나 `&`가 있어도(`git commit -m "feat(x): …" --no-verify`) 뒤쪽 옵션이 명령에서 떨어지지 않게 하기 위해서입니다. ②번 방식은 주석(`#` 뒤)과 `<<EOF`로 넣는 여러 줄 본문(heredoc)을 명령으로 보지 않고 건너뜁니다. 그 안의 작은따옴표 하나가 뒤 명령까지 따옴표로 묶어 버리지 않게 하기 위해서입니다. 두 방식 모두 다시 `|`로 나눠 단계별 명령으로 만들고, `2>&1`, `&>`처럼 리다이렉션에 쓰인 `&`는 경계로 보지 않습니다. 둘 중 하나라도 막기나 묻기가 나오면 그 결과를 따릅니다.
4. 각 명령 앞의 `NAME=값`, 셸 키워드(`if`, `then`, `do`, `while`, `!` 등), 명령 앞 리다이렉션(`2>/dev/null`, `> out.log`, `<<< 값`), `sudo`, `env`(`-S` 포함), `command`, `exec`(`-a` 포함), `nohup`, `time`, `nice`, `timeout`, `caffeinate`, `stdbuf`, `ionice`, `setsid`, `eval`, `bash -c`(`sh`, `zsh` 등과 `-lc` 같은 묶음 옵션, `bash -e -c`처럼 `-c` 앞에 다른 옵션이 붙은 경우 포함)를 벗기고 경로를 뗀 명령 이름(`/bin/rm` → `rm`)을 구합니다. 옵션 값도 함께 건너뜁니다(`sudo -u root`, `sudo -nu root`, `timeout -s KILL 30`).
5. 명령 이름별로 판정합니다. `rm`은 옵션 위치와 상관없이 재귀·강제 옵션과 대상을 보고, `git`은 앞쪽 전역 옵션(`-C 경로`, `-c 설정`, `--no-pager` 등)을 값까지 건너뛴 뒤 하위 명령(`push`, `reset`, `clean`)과 옵션을 봅니다. 포크 폭탄과 파이프 없는 다운로드 실행은 명령을 나누기 전에 전체 글자에서 따로 찾습니다. 다운로드 실행은 명령 자리의 셸(`bash`, `sh`, `eval`, `source`, `.` 등)만 보며, 앞에 `sudo`·`env`·리다이렉션(`2>/dev/null`)·셸 키워드(`if`, `elif` 등)가 붙어도 명령 자리로 봅니다.
6. 결과는 막기, 묻기, 통과 셋 중 하나입니다. 막기가 묻기보다 먼저입니다. 통과일 때는 아무것도 출력하지 않습니다.

## 한계

- 글자 모양만 봅니다. 변수에 담은 경로, 스크립트 파일 안의 명령, 다른 언어로 짠 프로그램, 인코딩한 문자열은 지나갈 수 있습니다.
- ①번 방식 때문에 따옴표 안 글자와 heredoc 본문도 명령처럼 판정되어 드물게 잘못 막을 수 있습니다(예: 문자열 안의 `; rm -rf ~`, 커밋 메시지 안의 `--no-verify`, heredoc 본문에 쓴 `rm -rf ~` 줄).
- `xargs`, `find -exec`, `su -c`, `ssh`처럼 4번 목록에 없는 명령이 다른 명령을 대신 실행하는 경우는 보지 못합니다.
- 명령이 만 줄이 넘을 만큼 길어 판정이 제한 시간(10초)을 넘기면 이 장치가 막지 못할 수 있습니다.
- 내려받은 내용을 셸이 아닌 실행기(`python3`, `node` 등)에 넘기는 경우도 보지 못합니다.
- 셸 명령에 내려받은 값을 인자로만 넘겨도(`bash build.sh "$(curl …)"`) 묻습니다.
- 샌드박스(격리 환경)가 아닙니다. 이 장치가 막지 않은 명령은 Claude Code의 평소 권한 확인 절차를 그대로 거칩니다. 허용 목록에 넣어 둔 명령이면 묻지 않고 바로 실행됩니다.

## PDF를 노트로 넣을 때

- 변환 도구(opendataloader-pdf)로 바꾸면 PDF는 내 컴퓨터 안에서 처리되고 키트는 밖으로 보내지 않습니다. 도구 자체의 네트워크 사용을 따로 측정하지는 못했습니다(확인 못 함).
- Claude가 PDF를 직접 읽으면 PDF 내용이 대화로 Claude에 전달됩니다. 남의 문서나 개인정보가 든 PDF는 이 경로로 보내도 되는지 먼저 판단하세요. `ask`로 노트를 읽을 때도 읽은 부분이 대화로 전달됩니다.
- 변환 스크립트는 노트 저장소 안의 지정한 폴더(기본 `PDF/`, `PDF/원본/`)에만 새 파일을 만듭니다. 같은 이름이 있으면 번호를 붙이고 덮어쓰지 않으며, `..` 경로 요소나 링크를 깨는 글자(`#`, `|`, `[`, `"` 등)가 든 폴더는 거부합니다. 원본과 그림을 먼저 넣고 노트는 마지막에 저장해서, 원본 복사가 실패하면 노트를 만들지 않습니다. 원본 PDF 자체는 지우거나 옮기지 않고 복사만 합니다.
- 스크립트가 설치를 하지는 않습니다. 설치 명령은 안내만 하고 사용자가 직접 실행합니다.

## 켜 두세요

- Claude Code의 권한 확인 창을 끄지 마세요. 이 키트의 점검은 그 위에 얹는 보조 장치입니다.
- 권한 확인을 모두 건너뛰는 우회 모드(bypass)는 쓰지 마세요.

## 운영 규칙이 Claude에게 요청하는 것

세션 시작 때 들어가는 규칙에 아래 내용이 있습니다.

- 삭제, 덮어쓰기, 외부 전송, 게시, 결제, 공개 전에는 반드시 먼저 묻습니다.
- 정리할 때는 지우지 않고 보관 폴더로 옮깁니다. 영구 삭제는 사용자가 합니다.
- 비밀값(API 키, 비밀번호, 토큰)은 출력하거나 파일에 쓰지 않습니다.

이것은 Claude가 따르도록 요청하는 규칙이고, 위의 명령 점검처럼 기계가 강제하는 것은 아닙니다.

## 막혔을 때

1. 막힌 이유 안내를 읽고 명령을 다시 확인합니다. 지울 폴더를 정확히 지정하면 대부분 통과합니다.
2. 확인한 뒤에도 꼭 필요하면 내 터미널에서 직접 실행하세요.
3. 점검 장치 자체가 계속 방해하면 `/plugin disable pro-agent@pro-agent`로 잠시 끌 수 있습니다. 일이 끝나면 다시 켜세요.

잘못 막힌 경우나 놓친 경우는 [GitHub 이슈](https://github.com/joymin5655/pro-agent/issues)로 알려 주세요.
