# Server-traffic-consumption-script  
# 服务器流量消耗脚本

测试系统为Debian12.13
使用方法：
1.获取网卡名称

```ip addr```

2.安装Aria2

```sudo apt install aria2```

3.下载脚本

```curl -O https://raw.githubusercontent.com/aelennb/Server-traffic-consumption-script/refs/heads/main/download.sh```

4.修改配置

 4.1编辑download.sh

```nano download.sh```

 4.2修改大文件URL

 4.3修改网卡名称
 
 4.2保存配置

 ```Ctrl+O```  保存
 ```Ctrl+X```  退出
 
5.赋予执行权限

```chmod +x download.sh```

6.执行脚本

```./download.sh```
