from datetime import datetime
from bs4 import BeautifulSoup
import os
import time
import mechanicalsoup
from hdbcli import dbapi
import requests
from bs4.element import Tag
import argparse

parser = argparse.ArgumentParser(
    description='Downloads Food Health Ratings in the UK and inserts them into an SAP HANA Table')

parser.add_argument('--user', required=True, help='User for SAP HANA connection')
parser.add_argument('--password', required=True, help='Password for SAP HANA connection')
parser.add_argument('--host', required=True, help='SAP HANA server')
parser.add_argument('--port', required=True, type=int, help='Port to SAP HANA tenant')
parser.add_argument('--schema', help='Schema inside SAP HANA tenant')
parser.add_argument('--batch', type=int, help='Group Inserts in batches of X rows for better throughput. Default is 3000', default=3000)
parser.add_argument('--table', help='Target Table Name. Default is "FHR"', default='FHR')


args = parser.parse_args()

user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.87 Safari/537.36"

if args.schema == None:
    tableName = args.user + '.' + args.table
else:
    tableName = args.schema + '.' + args.table

#Insert Batch size
INSERT_ARRAY_SIZE = args.batch

#  - - - - - - - - - SQL Statements - - - -
sql_select = " select top 1 * from " + tableName
sql_drop = "drop table " + tableName
sql_create = " create column table " + tableName + """( 
                                                ID int not null primary key, 
                                                BusinessName NVARCHAR(180),
                                                BusinessType NVARCHAR(180),
                                                RatingValue SMALLINT null,
                                                latitude double null,
                                                longitude double null,
                                                ScoreH smallint null,
                                                ScoreS smallint null,
                                                ScoreM smallint null,
                                                url NVARCHAR(512) null,
                                                pt ST_Point(1000004326) VALIDATION FULL BOUNDARY CHECK ON
                                                )"""
sql_create_idx = "create index IDX_LAT_"+args.table + " on "+tableName + " (latitude)"
sql_update = "update " + tableName + " set pt =NEW ST_Point(longitude, latitude).ST_SRID(1000004326) " \
                                     "where longitude is not null " \
                                     "and longitude is not null " \
                                     "and pt is null"
sql_insert = "insert into " + tableName + " (ID, BusinessName, BusinessType, RatingValue, latitude, longitude, url, scores,scorem,scoreh)  values (? , ?, ?,?, ?, ?, ?, ?, ?, ?)"
sql_delete = "delete from " + tableName + " where url=?"
sql_merge = "merge delta of " + tableName


url = "http://ratings.food.gov.uk/open-data/en-GB"


#connect !
print("Attempting to connect to SAP HANA at " + args.host + ':'+str(args.port))
conn = dbapi.connect(address=args.host, port=args.port, user=args.user, password=args.password)

print("Connection Established")

def parseInt(s):
    try:
        return int(s)
    except ValueError:
        return None

# Execute a piece of SQL and returns the status
def safeExecSQL(s):
    curs = conn.cursor()
    result = True
    try:
        curs.execute(s)
    except:
        result = False
        print("    query failed (" + s + ")")
    else:
        print("    query succeeded (" + s + ")")
    curs.close()
    return result

def execSQL(sql, verbose):
    curs = conn.cursor()
    if verbose == True:
        print("   Executing (" + sql + ")")
    curs.execute(sql)
    curs.close()

# Validates the target table
if safeExecSQL(sql_select):
    print("Target table is valid")
else:
    print("Failed to select from " + tableName)
    safeExecSQL(sql_drop)
    safeExecSQL(sql_create)
    safeExecSQL(sql_create_idx)
    execSQL(sql_select, False)

# removes env variables for proxy if outside the LAN and not on vpn
if 'HTTPS_PROXY' in os.environ or 'HTTP_PROXY' in os.environ:
    try:
        response = requests.get('https://www.twitter.com')
        if response.status_code == 200:
            print('online with proxy!')
    except:
        print('Failed to connect using proxy, trying direct')
        del os.environ["all_proxy"];
        del os.environ["http_proxy"];
        del os.environ["https_proxy"];

print('Opening page ', url)
browser = mechanicalsoup.StatefulBrowser()
# make it look like a real user
browser.set_user_agent(user_agent)
browser.open(url)
soup = browser.get_current_page()
files = []
links_in_page = soup.find_all("a")
for l in links_in_page:
    if l.get('href') is not None and type(l['href']) is str and l['href'].startswith(
            "http://ratings.food.gov.uk/OpenDataFiles/FHRS") and l.text.find("English language") >=0:
        files.append(l['href'])

print("found ",str(len(links_in_page))," links")
#print(soup)


browser.close()
nb_files = len(files)

print("Found " + str(nb_files) + " links to open")



lat = 1.1
long = 1.1
rval = 0
scores = 0
scorem = 0
scoreh = 0
arr = []

counter = 1

for f in files:
    # for y in range(3,len(files)):
    # f=files[y]
    print("Opening " + f + " " + str(counter) + "/" + str(nb_files))

    d1 = datetime.now()
    r = requests.get(f)
    soup = BeautifulSoup(r.text, "xml")
    restaurants = soup.find_all("EstablishmentDetail")

    for r in restaurants:
        if type(r.Geocode) == Tag and type(r.Geocode.Longitude) == Tag:
            long = (float)(r.Geocode.Longitude.text)
            lat = (float)(r.Geocode.Latitude.text)
        else:
            long = None
            lat = None

        if type(r.Scores) == Tag and type(r.Scores.Structural) == Tag:
            scores = parseInt(r.Scores.Structural.text)
            scorem = parseInt(r.Scores.ConfidenceInManagement.text)
            scoreh = parseInt(r.Scores.Hygiene.text)
        else:
            scores = None
            scorem = None
            scoreh = None
            # arr.append( ((int)(r.FHRSID.text), r.BusinessName.text, r.BusinessType.text, (int)(r.BusinessTypeID.text),rval,scoreh, scores, scorem, lat, long, r.AddressLine2, r.AddressLine3, r.AddressLine4))
        arr.append((
            parseInt(r.FHRSID.text),
            r.BusinessName.text,
            r.BusinessType.text,
            parseInt(r.RatingValue.text),
            lat,
            long,
            f,
            scores,
            scorem,
            scoreh
        ))

    curs = conn.cursor()
    conn.setautocommit(0);
    curs.execute(sql_delete, f)
    arr2 = []
    i = 0
#   inserts in batches
    for x in range(0, len(arr)):
        arr2.append(arr[x])
        if len(arr2) == INSERT_ARRAY_SIZE:
            i += len(arr2)
            print("   Inserting " + str(i) + "/" + str(len(arr)))
            curs.executemany(sql_insert, arr2)
            conn.commit()
            arr2.clear()
#   insert the remainder
    if len(arr2) > 0:
        try:
            print("   Inserting " + str(len(arr2)) + "/" + str(len(arr)))
            curs.executemany(sql_insert, arr2)
            conn.commit()
        except:
            print("   Error !! Failed on insert:")
            print(arr2)
    execSQL(sql_update, False)
    conn.commit()

    d2 = datetime.now()
    td = (datetime.now() - d1).total_seconds()
    th = int(round(len(arr)/td, 0))
    print(f, ";", len(arr), ";", td, ";", th)

#   wait before fetching next page to avoid making too many requests to the website
    time.sleep(0.1)
    arr.clear()
    counter += 1

# print(arr)
execSQL(sql_merge, True)