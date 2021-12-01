#!/bin/bash

email=monitor@layershift.com
password=`</dev/urandom tr -dc '123456789!@#$%qwe^CE' | head -c8`
user=check_monit
root_password=$2
sender=mysql-replication@layershift.com
confirmation=/var/lib/replication.txt

###Create user
function create_user () {
    echo "CREATE USER '$user'@'localhost' IDENTIFIED BY '$password';" | mysql -u$1 -p$root_password
    echo "GRANT SUPER , REPLICATION CLIENT ON * . * TO '$user'@'localhost' IDENTIFIED BY '$password' WITH MAX_QUERIES_PER_HOUR 0 MAX_CONNECTIONS_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0 MAX_USER_CONNECTIONS 0;"| mysql -uroot -p$root_password
}
###Check replication
function check_replication () {
    (echo "show slave status \G;") | mysql -u$user -p$password 2>&1 | grep "Slave_IO_Running: Yes"
    if [ "$?" != "0" ]
        then
            echo "Mysql replication broken on $hostname. Please check, and restart it" | /bin/mail  -s "Mysql replication broken on $hostname" $email
            rm -f $confirmation
    elif [ "$?" = "0" ] 
        then
            if [ -f $confirmation ] 
                then
                    exit 0  
                else
                    touch $confirmation ; echo "The replication was found working on `date`"
    fi
}

###Enable sendmail and mailx
function enable_mail () {
    /bin/systemctl enable sendmail
    /bin/systemctl start sendmail
    /bin/yum install mailx -y
}
if [ $1 != "check" ]
    then
        create_user
        enable_mail
elif [ $1 = "check" ]
    then
        check_replication
fi

