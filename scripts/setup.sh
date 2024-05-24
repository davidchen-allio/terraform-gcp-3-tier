gsutil cp -r gs://cloud-training/cepf/cepf020/flask_cloudsql_example_v1.zip .
apt-get install zip unzip wget python3-venv -y
unzip flask_cloudsql_example_v1.zip
cd flask_cloudsql_example/sqlalchemy
wget https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64 -O cloud_sql_proxy
chmod +x cloud_sql_proxy
export INSTANCE_HOST='127.0.0.1'
export DB_PORT='5432'
export DB_USER='postgres'
export DB_PASS='postgres'
export DB_NAME='cepf-db'
CONNECTION_NAME=$(gcloud sql instances describe cepf-instance --format="value(connectionName)")
nohup ./cloud_sql_proxy -instances=${CONNECTION_NAME}=tcp:5432 &
python3 -m venv env
source env/bin/activate
pip install -r requirements.txt
sed -i 's/127.0.0.1/0.0.0.0/g' app.py
sed -i 's/8080/80/g' app.py
nohup python app.py &
