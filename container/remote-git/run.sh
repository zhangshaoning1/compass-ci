

docker run -d -p 8100:8100 -v /srv/git:/git --name remote-git debian:remote-git

# test

echo you can use cmd: curl -H 'Content-Type: Application/json' -XPOST 'localhost:8100/git_command' -d '{"project": "smatch", "developer_repo": "smatch", "git_command": "git pull"}'
