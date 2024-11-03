#!/bin/bash

# AD Sunucu Bilgileri
AD_REALM="AD.LOCAL"
AD_DOMAIN="ad.local"
AD_SERVER="192.168.1.100"  # Active Directory sunucusunun IP adresini buraya yazın
AD_SERVER_FQDN="ad.domain.local"  # AD sunucusunun tam etki alanı adı
AD_ADMIN_USER="Administrator"  # Active Directory yönetici kullanıcı adı
AD_ADMIN_PASS="AdminPassword"  # AD yöneticisinin şifresi

# Gerekli Paketlerin Kurulumu
sudo apt update
sudo apt install -y freeradius freeradius-mysql freeradius-utils samba winbind libpam-winbind libnss-winbind krb5-user

# /etc/hosts Dosyasına AD Sunucusunu Ekleyin
echo "$AD_SERVER $AD_SERVER_FQDN" | sudo tee -a /etc/hosts

# /etc/resolv.conf Dosyasına AD DNS Sunucusunu Ekleyin
cat <<EOF | sudo tee /etc/resolv.conf
search $AD_DOMAIN
nameserver $AD_SERVER
EOF

# Kerberos Yapılandırması
cat <<EOF | sudo tee /etc/krb5.conf
[libdefaults]
    default_realm = $AD_REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    $AD_REALM = {
        kdc = $AD_SERVER
        admin_server = $AD_SERVER
    }

[domain_realm]
    .$AD_DOMAIN = $AD_REALM
    $AD_DOMAIN = $AD_REALM
EOF

# Kerberos Üzerinden KDC Testi (Kullanıcı oturum açma testi)
echo $AD_ADMIN_PASS | kinit $AD_ADMIN_USER
if [ $? -ne 0 ]; then
    echo "Kerberos oturum açma başarısız. Lütfen kullanıcı adı ve şifreyi kontrol edin."
    exit 1
fi
echo "Kerberos oturumu başarılı!"

# Samba Yapılandırması
sudo mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
cat <<EOF | sudo tee /etc/samba/smb.conf
[global]
   workgroup = ${AD_DOMAIN%%.*}
   security = ads
   realm = $AD_REALM
   domain master = no
   local master = no
   preferred master = no
   winbind use default domain = yes
   winbind offline logon = false
   idmap config * : range = 10000-20000
   template shell = /bin/bash
   kerberos method = secrets and keytab
EOF

# Sistemi Active Directory'ye Katma
echo $AD_ADMIN_PASS | sudo net ads join -U "$AD_ADMIN_USER%$AD_ADMIN_PASS"
if [ $? -ne 0 ]; then
    echo "AD'ye katılma başarısız. Lütfen ayarları kontrol edin."
    exit 1
fi
echo "Sistem AD'ye başarıyla katıldı!"

# Winbind ve Samba Servislerini Yeniden Başlatma
sudo systemctl restart smbd nmbd winbind
sudo systemctl enable smbd nmbd winbind

# FreeRADIUS MS-CHAP Ayarları
sudo ln -s /etc/freeradius/3.0/mods-available/mschap /etc/freeradius/3.0/mods-enabled/
sudo sed -i 's/#\s*winbind_username/winbind_username/g' /etc/freeradius/3.0/mods-available/mschap
sudo sed -i 's/#\s*winbind_domain/winbind_domain/g' /etc/freeradius/3.0/mods-available/mschap
sudo sed -i 's/#\s*with_ntdomain_hack = yes/with_ntdomain_hack = yes/' /etc/freeradius/3.0/mods-available/mschap

# ntlm_auth Ayarları
sudo sed -i '/ntlm_auth/s/^#//g' /etc/freeradius/3.0/mods-available/mschap
sudo sed -i '/ntlm_auth/s|/path/to/ntlm_auth|/usr/bin/ntlm_auth|g' /etc/freeradius/3.0/mods-available/mschap
sudo sed -i "/ntlm_auth/s|%{mschap:User-Name}|%{mschap:User-Name}|g" /etc/freeradius/3.0/mods-available/mschap

# FreeRADIUS’u Yeniden Başlatma
sudo systemctl restart freeradius

# Test Etme (FreeRADIUS'u debug modda çalıştırma)
/usr/sbin/freeradius -X
------------------------------------------------------------------
# Winbind servisi çalışmazsa FreeRADIUS AD ile iletişim kuramaz. Aşağıdaki komutla winbind servisinin durumunu kontrol edin:
sudo systemctl status winbind 
# AD bağlantısını kontrol etmek için aşağıdaki komutları kullanın:
wbinfo -u
# NTLM Authentication (ntlm_auth) aracının FreeRADIUS tarafından doğru çalışıp çalışmadığını kontrol edin
ntlm_auth --request-nt-key --domain=domain.local --username=radius
# FreeRADIUS kullanıcısının Samba'nın kimlik doğrulama yetkisine erişmesi için freerad kullanıcısını winbindd_priv grubuna ekleyin:
sudo usermod -aG winbindd_priv freerad
# Winbind ve FreeRADIUS servislerini yeniden başlatın:
sudo systemctl restart winbind
sudo systemctl restart freeradius
# Kerberos biletiyle ilgili bir sorun varsa, AD yönetici hesabınızla tekrar Kerberos bileti almayı deneyin:
kinit Administrator
