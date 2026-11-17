#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""github_api.py — 小柠檬内核 GitHub 直连工具 v1.0（261116）
走 api.github.com REST API（设备实测可达；github.com git 通道不可达，故用 Git Data API 提交，不用 git push）。
动作（request JSON 的 action 字段）：
  user                          查当前令牌账号
  repos                         列我的仓库
  create_repo {name,private,description}   建仓库（默认 private）
  list_files  {repo,branch}     列仓库文件树
  get_file    {repo,path,branch} 读文件内容
  upload_dir  {local_dir,repo,branch,message}  整目录提交（Git Data API，自动排除凭据）
配置：同目录 github.conf（GITHUB_TOKEN 必填，GITHUB_OWNER 可选），环境变量可覆盖。
"""
import sys, os, json, base64, re, urllib.request, urllib.parse, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
API = 'https://api.github.com'
UA = 'lemon-kernel-github/1.0'

SECRET_PAT = re.compile(r'(^|/)(\.token[^/]*|\.tokens\.json|\.cmdguard\.json|ai\.conf|search\.conf|github\.conf)$')
SKIP_DIR = {'.git', '__pycache__', 'tasks', 'logs', 'recycle', 'status', 'snapshots'}
SKIP_EXT = ('.pyc', '.log', '.cpio')

def load_conf():
    conf = {}
    try:
        for line in open(os.path.join(HERE, 'github.conf'), encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                conf[k.strip()] = v.strip()
    except OSError:
        pass
    for k in ('GITHUB_TOKEN', 'GITHUB_OWNER'):
        if os.environ.get(k):
            conf[k] = os.environ[k]
    return conf

def need_token(conf):
    t = conf.get('GITHUB_TOKEN', '')
    if not t or t.startswith('<'):
        print('[github] 未配置 GITHUB_TOKEN（github.conf），无法连接')
        sys.exit(3)
    return t

def req(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(API + path, data=data, method=method, headers={
        'Authorization': 'Bearer ' + token,
        'Accept': 'application/vnd.github+json',
        'User-Agent': UA,
        'X-GitHub-Api-Version': '2022-11-28',
    })
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'message': raw.decode('utf-8', 'ignore')[:200]}
    except Exception as e:
        return 0, {'message': repr(e)}

def is_secret(rel):
    if SECRET_PAT.search(rel):
        return True
    parts = rel.split('/')
    if any(p in SKIP_DIR for p in parts):
        return True
    if rel.endswith(SKIP_EXT) or '.bak' in os.path.basename(rel):
        return True
    return False

def split_repo(conf, repo):
    if '/' in repo:
        return repo.split('/', 1)
    owner = conf.get('GITHUB_OWNER')
    if not owner:
        st, d = req('GET', '/user', need_token(conf))
        owner = d.get('login', '')
    return owner, repo

def act_user(conf, a):
    t = need_token(conf)
    st, d = req('GET', '/user', t)
    if st != 200:
        print('[github] user 失败 %s: %s' % (st, d.get('message', ''))); return
    print('[github] login=%s name=%s plan=%s public_repos=%s' % (
        d.get('login'), d.get('name'), (d.get('plan') or {}).get('name'), d.get('public_repos')))

def act_repos(conf, a):
    t = need_token(conf)
    st, d = req('GET', '/user/repos?per_page=100&sort=updated', t)
    if st != 200:
        print('[github] repos 失败 %s: %s' % (st, d.get('message', ''))); return
    print('[github] repos=%d' % len(d))
    for r in d:
        print('  %s | %s | updated=%s' % (r['full_name'], 'private' if r['private'] else 'public', r.get('updated_at', '')[:10]))

def act_create_repo(conf, a):
    t = need_token(conf)
    name = a.get('name')
    if not name:
        print('[github] create_repo 需 name'); return
    body = {'name': name, 'private': a.get('private', True),
            'description': a.get('description', ''), 'auto_init': False}
    st, d = req('POST', '/user/repos', t, body)
    if st not in (201,):
        print('[github] create_repo 失败 %s: %s' % (st, d.get('message', ''))); return
    print('[github] created %s | %s | %s' % (d['full_name'], 'private' if d['private'] else 'public', d['html_url']))

def act_list_files(conf, a):
    t = need_token(conf)
    owner, repo = split_repo(conf, a.get('repo', ''))
    branch = a.get('branch', 'main')
    st, d = req('GET', '/repos/%s/%s/git/trees/%s?recursive=1' % (owner, repo, branch), t)
    if st != 200:
        print('[github] list_files 失败 %s: %s' % (st, d.get('message', ''))); return
    tree = d.get('tree', [])
    print('[github] %s/%s@%s files=%d' % (owner, repo, branch, len(tree)))
    for e in tree:
        if e['type'] == 'blob':
            print('  %s (%sB)' % (e['path'], e.get('size', '?')))

def act_get_file(conf, a):
    t = need_token(conf)
    owner, repo = split_repo(conf, a.get('repo', ''))
    path = a.get('path', '')
    branch = a.get('branch', 'main')
    enc = urllib.parse.quote(path)
    st, d = req('GET', '/repos/%s/%s/contents/%s?ref=%s' % (owner, repo, enc, branch), t)
    if st != 200:
        print('[github] get_file 失败 %s: %s' % (st, d.get('message', ''))); return
    content = base64.b64decode(d.get('content', '')).decode('utf-8', 'ignore')
    print('[github] %s/%s:%s (%dB)' % (owner, repo, path, len(content)))
    print(content)

def act_upload_dir(conf, a):
    t = need_token(conf)
    local = a.get('local_dir', '')
    if not os.path.isdir(local):
        print('[github] upload_dir local_dir 不存在: %s' % local); return
    owner, repo = split_repo(conf, a.get('repo', ''))
    branch = a.get('branch', 'main')
    message = a.get('message', 'lemon-kernel sync %s' % __import__('time').strftime('%Y-%m-%d %H:%M'))
    # 收集文件（排除凭据/运行时）
    files = []
    for root, dirs, fns in os.walk(local):
        dirs[:] = [d for d in dirs if d not in SKIP_DIR and not d.startswith('.')]
        for fn in sorted(fns):
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, local).replace(os.sep, '/')
            if is_secret(rel):
                continue
            files.append((rel, full))
    if not files:
        print('[github] upload_dir 无可上传文件'); return
    # 仓库存在性
    st, rd = req('GET', '/repos/%s/%s' % (owner, repo), t)
    if st != 200:
        print('[github] 仓库 %s/%s 不存在或无权限 (%s)，先 create_repo' % (owner, repo, st)); return
    branch = rd.get('default_branch', branch)
    # 基线 ref（空仓库处理）
    st, refd = req('GET', '/repos/%s/%s/git/ref/heads/%s' % (owner, repo, branch), t)
    base_sha = None
    if st == 200:
        base_sha = refd['object']['sha']
    # blobs
    entries = []
    for rel, full in files:
        data = open(full, 'rb').read()
        st, bd = req('POST', '/repos/%s/%s/git/blobs' % (owner, repo), t,
                     {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
        if st != 201:
            print('[github] blob 失败 %s %s: %s' % (rel, st, bd.get('message', ''))); return
        entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': bd['sha']})
    # tree
    tree_body = {'tree': entries}
    if base_sha:
        tree_body['base_tree'] = base_sha
    st, td = req('POST', '/repos/%s/%s/git/trees' % (owner, repo), t, tree_body)
    if st != 201:
        print('[github] tree 失败 %s: %s' % (st, td.get('message', ''))); return
    # commit
    commit_body = {'message': message, 'tree': td['sha']}
    if base_sha:
        commit_body['parents'] = [base_sha]
    st, cd = req('POST', '/repos/%s/%s/git/commits' % (owner, repo), t, commit_body)
    if st != 201:
        print('[github] commit 失败 %s: %s' % (st, cd.get('message', ''))); return
    # ref
    if base_sha:
        st, ud = req('PATCH', '/repos/%s/%s/git/refs/heads/%s' % (owner, repo, branch), t,
                     {'sha': cd['sha'], 'force': False})
    else:
        st, ud = req('POST', '/repos/%s/%s/git/refs' % (owner, repo), t,
                     {'ref': 'refs/heads/%s' % branch, 'sha': cd['sha']})
    if st not in (200, 201):
        print('[github] ref 更新失败 %s: %s' % (st, ud.get('message', ''))); return
    print('[github] uploaded %s/%s@%s files=%d commit=%s' % (owner, repo, branch, len(files), cd['sha'][:10]))
    print('  https://github.com/%s/%s' % (owner, repo))

ACTIONS = {'user': act_user, 'repos': act_repos, 'create_repo': act_create_repo,
           'list_files': act_list_files, 'get_file': act_get_file, 'upload_dir': act_upload_dir}

def main():
    if len(sys.argv) < 2:
        print('[github] usage: github_api.sh \'{"action":"user"}\''); sys.exit(1)
    try:
        a = json.loads(sys.argv[1])
    except Exception:
        print('[github] request 须为合法 JSON'); sys.exit(1)
    act = a.get('action', '')
    if act not in ACTIONS:
        print('[github] 未知 action: %s（可用: %s）' % (act, ','.join(ACTIONS))); sys.exit(1)
    conf = load_conf()
    ACTIONS[act](conf, a)

if __name__ == '__main__':
    main()
