-- create a user for GIS with no password expiration
CREATE USER GIS password JaimeLe20 no FORCE_FIRST_PASSWORD_CHANGE VALID untIL FOREVER;

--create a schema
create schema food_rating;

--grant permissions to the user
grant data admin to GIS;
grant select,execute,create any on schema food_rating to GIS ;

grant select on "PUBLIC"."ST_SPATIAL_REFERENCE_SYSTEMS"  to GIS ;
grant select on "PUBLIC"."ST_GEOMETRY_COLUMNS"  to GIS ;


create or replace function food_rating.find( NameStartsWith NVARCHAR(64) DEFAULT '')
/* This function returns all businesses with a location whose name start with the specified string.
The default value is an empty string which returns the whole dataset.
The comparison is case insensitive.
*/

RETURNS
  TABLE (
 	ID 			 INT not null,
 	businessname NVARCHAR(128),
 	businesstype NVARCHAR(128),
 	longitude    double,
 	latitude     double,
 	pt 	         ST_Geometry(1000004326),
 	ratingvalue  smallint
  ) LANGUAGE SQLSCRIPT as
begin

	return select id, initcap(businessname) as businessname,businesstype, longitude, latitude, pt, ratingvalue
		from food_rating.FHR
		where pt is not null
		  and InitCap(businessname) like InitCap(NameStartsWith)||'%'
		order by longitude;
end;

-------------------------------------------------------------------------------
-- Aspherical geoclustering

CREATE or replace function food_rating.f_bad_hygiene(VIEW_EXTENT NVARCHAR(400))
returns
TABLE (
	ID int,
    bin_num int,
	KPI_PER_KM2 double,
	shape st_geometry(4326),
	surface_km double,
	cnt  int
)
lANGUAGE SQLSCRIPT as
begin
   declare xmin double;
   declare xmax double;
   declare ymin double;
   declare ymax double;
   declare surface_km double;
   declare view_surface_km double;

   declare eps_degree double;

   select bbox.ST_XMin(),
          bbox.ST_XMax(),
          bbox.ST_YMin(),
          bbox.ST_YMax(),
          bbox.ST_Area('kilometer')
          into xmin, xmax, ymin, ymax, view_surface_km
   from (select ST_GeomFromText(:VIEW_EXTENT, 4326) as bbox from dummy);


	return select ID,
	       BINNING(VALUE => KPI_PER_KM2, TILE_COUNT => 5) OVER () AS bin_num,
	       KPI_PER_KM2,
	       --shape.ST_Buffer(50,'meter') as shape,
	       shape.ST_SRID(1000004326).ST_Buffer(50,'meter').ST_SRID(4326) as shape,
	       surface_km,
	       cnt
	from(
	    SELECT ST_ClusterID() as ID,
	       count(*)/ST_ConcaveHullAggr(pt).ST_SRID(4326).ST_Area('kilometer') AS KPI_PER_KM2,
	       ST_ConcaveHullAggr(pt).ST_SRID(4326) as SHAPE,
	       ST_ConcaveHullAggr(pt).ST_SRID(4326).ST_Area('kilometer') as surface_km,
	       to_integer(COUNT(*)) AS CNT
	    FROM food_rating.FHR f
	    WHERE 1=1
	      AND ST_GeomFromText(:view_extent, 1000004326).ST_Contains(pt) = 1
	      AND ratingvalue <=3
	    GROUP cluster by pt
	    using DBSCAN
	    EPS 0.00225
	    MINPTS 20
	    HAVING st_clusterid()<>0
	)n ;

end;

----------------------------------------------------------------------------------
-- Compute hexadecimal clustering and apply a predictive score

CREATE or replace function food_rating.f_hex(VIEW_EXTENT NVARCHAR(400), radius int)
returns
TABLE (
	ID int,
	shape st_geometry(4326),
	predict_pret_a_manger double,
	NB_RETAIL_BIG int,
	NB_RETAIL_SMALL int,
	NB_BAR int,
	NB_SANDWICH int,
	NB_RESTAURANT int,
	NB_LT_3 int,
	NB_RESTAURANT_5 int,
	AVG_BAR  int,
	radius int
)
lANGUAGE SQLSCRIPT as
begin

   declare xmin double;
   declare xmax double;
   declare ymin double;
   declare ymax double;

   --declare radius int = 150;

   declare diameter int = :radius* 2 ;
   declare x int;
   declare y int;
   declare surface_km double;
   declare view_surface_km double;

   declare cat_retail_big   nvarchar(64)= 'Retailers - supermarkets/hypermarkets';
    declare cat_retail_small nvarchar(64)= 'Retailers - other';
    declare cat_bar          nvarchar(64)= 'Pub/bar/nightclub';
    declare cat_sandwich     nvarchar(64)= 'Takeaway/sandwich shop';
    declare cat_restaurant   nvarchar(64)= 'Restaurant/Cafe/Canteen';

   select floor(bbox.ST_XMin()),
          bbox.ST_XMax(),
          floor(bbox.ST_YMin()),
          bbox.ST_YMax(),
          bbox.ST_Area('kilometer')
          into xmin, xmax, ymin, ymax, view_surface_km
   from (select ST_GeomFromText(:VIEW_EXTENT, 4326) as bbox from dummy)n;

   select greatest(new ST_Point('Point ('||:xmin||' '||:ymin||')',4326).ST_Distance(new ST_Point('Point ('||:xmax||' '||:ymin||')',4326),'meter')/:diameter, 1),
          greatest(new ST_Point('Point ('||:xmin||' '||:ymin||')',4326).ST_Distance(new ST_Point('Point ('||:xmin||' '||:ymax||')',4326),'meter')/:diameter, 1)
          into x , y
   from dummy;

   --sphere of an hexagon
   surface_km= 3. * sqrt(3) * :radius/1000 * :radius/1000 / 2;

   transform_pt = select --pt.ST_SRID(0) as pt,
                  pt.ST_Transform(3857) as pt,
                  businesstype,
                  ratingvalue,
                  LONGITUDE,
                  LATITUDE
   from "FOOD_RATING"."FHR"
		  where LONGITUDE BETWEEN :xmin and :xmax
	        and LATITUDE BETWEEN :ymin AND :ymax ;


   clusters=select ST_clusterid() as id,
		           ST_ClusterCell() as shape,
		            to_integer(sum(case businesstype when :cat_retail_big   then 1 else 0 end)/:surface_km) as NB_RETAIL_BIG,
				    to_integer(sum(case businesstype when :cat_retail_small then 1 else 0 end)/:surface_km) as NB_RETAIL_SMALL,
				    to_integer(sum(case businesstype when :cat_bar          then 1 else 0 end)/:surface_km) as NB_BAR,
				    to_integer(sum(case businesstype when :cat_sandwich     then 1 else 0 end)/:surface_km) as NB_SANDWICH,
				    to_integer(sum(case businesstype when :cat_restaurant   then 1 else 0 end)/:surface_km) as NB_RESTAURANT,
				    to_integer(sum(case when ratingvalue <=3 then 1 else 0 end)/:surface_km) as NB_LT_3,
				    to_integer(sum(case when businesstype = :cat_restaurant and ratingvalue=5 then 1 else 0 end)/:surface_km) as NB_RESTAURANT_5,
				    to_decimal(avg(case businesstype when :cat_bar          then ratingvalue end),2,1) as AVG_BAR
		  from :transform_pt
   		  group CLUSTER BY pt
	     USING hexagon X CELLS :y
	     having count(*)>5;

   prediction = select id,shape,
   CAST( (  CAST( (CASE
WHEN ( "NB_RETAIL_BIG" IS NULL ) THEN -1.361730523606014e-2
WHEN "NB_RETAIL_BIG" <= 0.0e0 THEN -2.7950331124786877e-2
WHEN "NB_RETAIL_BIG" < 7.0e0 THEN -4.2283357013513614e-2
WHEN "NB_RETAIL_BIG" <= 7.0e0 THEN -1.748461258403303e-2
WHEN "NB_RETAIL_BIG" < 1.5e1 THEN -3.1817638472759771e-2
WHEN "NB_RETAIL_BIG" <= 1.5e1 THEN 1.0735952175239604e-2
WHEN "NB_RETAIL_BIG" < 2.3e1 THEN -3.5970737134871367e-3
WHEN "NB_RETAIL_BIG" <= 2.3e1 THEN 4.9653701858233451e-2
WHEN "NB_RETAIL_BIG" <= 3.1e1 THEN 3.5320675969506714e-2
WHEN "NB_RETAIL_BIG" <= 3.9e1 THEN 2.0987650080779977e-2
WHEN "NB_RETAIL_BIG" <= 4.7e1 THEN 6.6546241920532323e-3
WHEN "NB_RETAIL_BIG" <= 5.5e1 THEN -7.678401696673498e-3
WHEN "NB_RETAIL_BIG" > 5.5e1 THEN -2.2011427585400242e-2
ELSE -2.2011427585400242e-2
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_RETAIL_SMALL" IS NULL ) THEN -2.459061087456034e-2
WHEN "NB_RETAIL_SMALL" <= 0.0e0 THEN 9.9351157685090341e-2
WHEN "NB_RETAIL_SMALL" <= 6.0e0 THEN  ( -4.0822892721835424e-4*"NB_RETAIL_SMALL"+9.9351157684804861e-2 )
WHEN "NB_RETAIL_SMALL" <= 7.0e0 THEN 8.725775056227647e-2
WHEN "NB_RETAIL_SMALL" <= 1.2e1 THEN  ( -2.1153601179822014e-3*"NB_RETAIL_SMALL"+1.020652713870083e-1 )
WHEN "NB_RETAIL_SMALL" <= 1.5e1 THEN  ( -7.857730731337817e-3*"NB_RETAIL_SMALL"+1.7332884716829716e-1 )
WHEN "NB_RETAIL_SMALL" <= 2.6e1 THEN  ( -2.0272908251304554e-3*"NB_RETAIL_SMALL"+8.5872248572770982e-2 )
WHEN "NB_RETAIL_SMALL" <= 3.9e1 THEN  ( -1.9827429430342314e-3*"NB_RETAIL_SMALL"+8.4673184383499842e-2 )
WHEN "NB_RETAIL_SMALL" <= 4.6e1 THEN  ( -2.833011179974611e-3*"NB_RETAIL_SMALL"+1.1783364562195173e-1 )
WHEN "NB_RETAIL_SMALL" <= 7.0e1 THEN  ( -6.8588594581749584e-4*"NB_RETAIL_SMALL"+1.7248431819687271e-2 )
WHEN "NB_RETAIL_SMALL" <= 9.0e1 THEN  ( -9.3909355277607611e-5*"NB_RETAIL_SMALL"-2.4210089711783143e-2 )
WHEN "NB_RETAIL_SMALL" <= 1.11e2 THEN  ( -9.390935527760734e-5*"NB_RETAIL_SMALL"-2.421008971197549e-2 )
WHEN "NB_RETAIL_SMALL" <= 1.19e2 THEN  ( 3.7301452280553548e-4*"NB_RETAIL_SMALL"-7.6038640178896943e-2 )
WHEN "NB_RETAIL_SMALL" <= 1.27e2 THEN  ( 3.7301452280553781e-4*"NB_RETAIL_SMALL"-7.603864017858987e-2 )
WHEN "NB_RETAIL_SMALL" <= 1.46e2 THEN  ( -7.49143283291994e-4*"NB_RETAIL_SMALL"+6.701620013707954e-2 )
WHEN "NB_RETAIL_SMALL" <= 1.51e2 THEN  ( -6.0727426412202357e-3*"NB_RETAIL_SMALL"+8.4621557315327056e-1 )
WHEN "NB_RETAIL_SMALL" <= 7.71e2 THEN  ( -4.0822892721835397e-4*"NB_RETAIL_SMALL"-3.5369577153728016e-2 )
ELSE -3.501140800390789e-1
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_BAR" IS NULL ) THEN 3.0746181196412953e-2
WHEN "NB_BAR" <= 0.0e0 THEN -9.8528609338195475e-3
WHEN "NB_BAR" <= 1.4e1 THEN  ( -1.6970795346406126e-4*"NB_BAR"-9.8528609340726991e-3 )
WHEN "NB_BAR" <= 2.3e1 THEN  ( 1.9928035227595193e-3*"NB_BAR"-4.2110408282849093e-2 )
WHEN "NB_BAR" <= 2.5e1 THEN  ( 7.3553980153759912e-3*"NB_BAR"-1.6545008161086716e-1 )
WHEN "NB_BAR" <= 3.1e1 THEN  ( 1.7680659352272588e-3*"NB_BAR"-2.0527730924823941e-2 )
WHEN "NB_BAR" <= 5.0e1 THEN  ( -3.2441155776558039e-4*"NB_BAR"+4.4339071357328154e-2 )
WHEN "NB_BAR" <= 6.3e1 THEN  ( 6.475061201431688e-4*"NB_BAR"-4.5424859519930805e-3 )
WHEN "NB_BAR" <= 2.78e2 THEN  ( -1.0687288568404312e-3*"NB_BAR"+1.2538692347796987e-1 )
ELSE -1.7171969872366999e-1
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_SANDWICH" IS NULL ) THEN 1.4166482289329572e-3
WHEN "NB_SANDWICH" <= 0.0e0 THEN 4.5285363332635692e-3
WHEN "NB_SANDWICH" <= 6.0e0 THEN  ( -1.0670706200632584e-3*"NB_SANDWICH"+4.5285363325173605e-3 )
WHEN "NB_SANDWICH" <= 7.0e0 THEN 9.1817868001289327e-3
WHEN "NB_SANDWICH" <= 2.3e1 THEN  ( -3.4194953088760019e-4*"NB_SANDWICH"+1.1575433515770615e-2 )
WHEN "NB_SANDWICH" <= 3.9e1 THEN  ( -1.9922123760858889e-4*"NB_SANDWICH"+8.1901703075253664e-3 )
WHEN "NB_SANDWICH" <= 4.4e1 THEN  ( -3.3862163190149785e-3*"NB_SANDWICH"+1.5902607220211873e-1 )
WHEN "NB_SANDWICH" <= 4.7e1 THEN  ( -1.5741344154025394e-2*"NB_SANDWICH"+7.1162895244327407e-1 )
WHEN "NB_SANDWICH" <= 5.1e1 THEN  ( 6.0112343478581631e-3*"NB_SANDWICH"-3.7751980388895401e-1 )
WHEN "NB_SANDWICH" <= 5.5e1 THEN  ( 1.3556987214761951e-2*"NB_SANDWICH"-7.6779413440963162e-1 )
WHEN "NB_SANDWICH" <= 5.9e1 THEN  ( 8.8475328809821674e-3*"NB_SANDWICH"-5.0877414604746429e-1 )
WHEN "NB_SANDWICH" <= 7.9e1 THEN  ( -4.3556767545588094e-4*"NB_SANDWICH"+4.6693576510841425e-2 )
WHEN "NB_SANDWICH" <= 1.14e2 THEN  ( -7.2792528211267082e-4*"NB_SANDWICH"+6.9789827434130355e-2 )
WHEN "NB_SANDWICH" <= 1.19e2 THEN  ( 2.2108143997945584e-2*"NB_SANDWICH"-2.5491271336083439e0 )
WHEN "NB_SANDWICH" <= 3.02e2 THEN  ( -1.0670706200632586e-3*"NB_SANDWICH"+3.0876266040065364e-1 )
ELSE -1.3492666858450464e-2
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_RESTAURANT" IS NULL ) THEN 9.7384818105304513e-2
WHEN "NB_RESTAURANT" <= 0.0e0 THEN -2.2642420131437851e-1
WHEN "NB_RESTAURANT" <= 2.2e1 THEN  ( 2.5833415655551246e-4*"NB_RESTAURANT"-2.2642420131378493e-1 )
WHEN "NB_RESTAURANT" <= 2.3e1 THEN -2.0675674238330899e-1
WHEN "NB_RESTAURANT" <= 3.2e1 THEN  ( 1.7812152568338099e-3*"NB_RESTAURANT"-2.4772469328888314e-1 )
WHEN "NB_RESTAURANT" <= 3.9e1 THEN  ( 2.7924701324077059e-3*"NB_RESTAURANT"-2.8009802614563178e-1 )
WHEN "NB_RESTAURANT" <= 5.4e1 THEN  ( 1.369720257851951e-3*"NB_RESTAURANT"-2.2461078103577534e-1 )
WHEN "NB_RESTAURANT" <= 6.3e1 THEN  ( 4.5912050459194081e-3*"NB_RESTAURANT"-4.0157143611497104e-1 )
WHEN "NB_RESTAURANT" <= 9.9e1 THEN  ( 1.2049747056006596e-3*"NB_RESTAURANT"-1.8823892467043979e-1 )
WHEN "NB_RESTAURANT" <= 1.19e2 THEN  ( 3.8089172176304308e-3*"NB_RESTAURANT"-4.4845306183311279e-1 )
WHEN "NB_RESTAURANT" <= 1.34e2 THEN  ( 4.6880822619298265e-3*"NB_RESTAURANT"-5.5307370209757523e-1 )
WHEN "NB_RESTAURANT" <= 1.59e2 THEN  ( 1.9524635093522795e-3*"NB_RESTAURANT"-1.8572239074804245e-1 )
WHEN "NB_RESTAURANT" <= 2.33e2 THEN  ( 8.1772133291778718e-4*"NB_RESTAURANT"-5.2983846888374278e-3 )
WHEN "NB_RESTAURANT" <= 2.7e2 THEN  ( 2.6568719510140348e-3*"NB_RESTAURANT"-4.3538721769340505e-1 )
WHEN "NB_RESTAURANT" <= 2.79e2 THEN  ( 9.5395396296089861e-3*"NB_RESTAURANT"-2.2937074909051298e0 )
WHEN "NB_RESTAURANT" <= 2.98e2 THEN  ( 2.4968109874153629e-3*"NB_RESTAURANT"-3.2637940306621577e-1 )
WHEN "NB_RESTAURANT" <= 3.08e2 THEN  ( -4.0785247899053851e-3*"NB_RESTAURANT"+1.6354616897631158e0 )
WHEN "NB_RESTAURANT" <= 3.18e2 THEN  ( -4.0785247899053851e-3*"NB_RESTAURANT"+1.635461689759113e0 )
WHEN "NB_RESTAURANT" <= 3.19e2 THEN  ( -2.8826411494890181e-2*"NB_RESTAURANT"+9.5052896619400542e0 )
WHEN "NB_RESTAURANT" <= 1.782e3 THEN  ( 2.5833415655551219e-4*"NB_RESTAURANT"+2.1376047516194824e-1 )
ELSE 6.7411194214387093e-1
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_LT_3" IS NULL ) THEN -2.6624762467005302e-3
WHEN "NB_LT_3" <= 0.0e0 THEN 1.9626797137833329e-2
WHEN "NB_LT_3" <= 6.0e0 THEN  ( 1.6867470224479996e-5*"NB_LT_3"+1.9626797137845126e-2 )
WHEN "NB_LT_3" <= 7.0e0 THEN 1.334302331302073e-2
WHEN "NB_LT_3" <= 1.7e1 THEN  ( -5.8713851107473328e-4*"NB_LT_3"+1.7452992889921443e-2 )
WHEN "NB_LT_3" <= 3.1e1 THEN  ( -3.6095987120715161e-4*"NB_LT_3"+1.3472479979306222e-2 )
WHEN "NB_LT_3" <= 7.16e2 THEN  ( 1.6867470224479786e-5*"NB_LT_3"-3.3034401140871455e-3 )
ELSE 8.7736685666403805e-3
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "NB_RESTAURANT_5" IS NULL ) THEN 3.714722044609222e-2
WHEN "NB_RESTAURANT_5" <= 0.0e0 THEN -4.2516768033135532e-2
WHEN "NB_RESTAURANT_5" <= 7.0e0 THEN  ( -2.8090106405611486e-3*"NB_RESTAURANT_5"-4.2516768035323269e-2 )
WHEN "NB_RESTAURANT_5" <= 1.5e1 THEN  ( -2.8090106405611465e-3*"NB_RESTAURANT_5"-4.2516768037511019e-2 )
WHEN "NB_RESTAURANT_5" <= 1.9e1 THEN  ( 5.3660030488985599e-3*"NB_RESTAURANT_5"-1.6985549478375636e-1 )
WHEN "NB_RESTAURANT_5" <= 2.3e1 THEN  ( 7.9320626972395527e-3*"NB_RESTAURANT_5"-2.2027780347540793e-1 )
WHEN "NB_RESTAURANT_5" <= 4.5e1 THEN  ( 1.1847774415653315e-3*"NB_RESTAURANT_5"-6.5090242592246716e-2 )
WHEN "NB_RESTAURANT_5" <= 6.3e1 THEN  ( 1.9209181565774873e-3*"NB_RESTAURANT_5"-9.8512311013410778e-2 )
WHEN "NB_RESTAURANT_5" <= 1.2e2 THEN  ( 5.8566750374628546e-4*"NB_RESTAURANT_5"-1.4391519881671659e-2 )
WHEN "NB_RESTAURANT_5" <= 2.06e2 THEN  ( 2.6545426358061354e-4*"NB_RESTAURANT_5"+2.4225991269720089e-2 )
WHEN "NB_RESTAURANT_5" <= 2.1e2 THEN  ( 4.5708275056914882e-3*"NB_RESTAURANT_5"-8.626808966028392e-1 )
WHEN "NB_RESTAURANT_5" <= 2.28e2 THEN  ( 3.8488231038514057e-4*"NB_RESTAURANT_5"+2.0515115386141022e-2 )
WHEN "NB_RESTAURANT_5" <= 2.37e2 THEN  ( -7.454695064042921e-4*"NB_RESTAURANT_5"+2.7840922989297257e-1 )
WHEN "NB_RESTAURANT_5" <= 2.46e2 THEN  ( -7.4546950640429557e-4*"NB_RESTAURANT_5"+2.7840922989230865e-1 )
WHEN "NB_RESTAURANT_5" <= 2.68e2 THEN  ( -2.9743646164305716e-4*"NB_RESTAURANT_5"+1.6819310088037606e-1 )
WHEN "NB_RESTAURANT_5" <= 2.9e2 THEN  ( -2.9743646164305656e-4*"NB_RESTAURANT_5"+1.6819310087970846e-1 )
WHEN "NB_RESTAURANT_5" <= 3.21e2 THEN  ( 2.1164457105232135e-4*"NB_RESTAURANT_5"+2.0107084925199817e-2 )
WHEN "NB_RESTAURANT_5" <= 3.34e2 THEN  ( 1.4273958967759616e-3*"NB_RESTAURANT_5"-3.7134534807647174e-1 )
WHEN "NB_RESTAURANT_5" <= 7.24e2 THEN  ( -1.7686369080825433e-6*"NB_RESTAURANT_5"+1.2316849641864223e-1 )
ELSE 1.2188800329719048e-1
END) AS DOUBLE)+
 CAST( (CASE
WHEN ( "AVG_BAR" IS NULL ) THEN -9.9169417569354643e-3
WHEN "AVG_BAR" <= 0.0e0 THEN 4.5277258234105562e-2
WHEN "AVG_BAR" <= 3.9960000514994132e0 THEN  ( -6.9026543579197063e-3*"AVG_BAR"+4.5277258231347262e-2 )
WHEN "AVG_BAR" <= 4.0000000000010001e0 THEN  ( 4.3953736504400958e0*"AVG_BAR"-1.7546219082450008e1 )
WHEN "AVG_BAR" <= 4.1384615384625381e0 THEN  ( 1.2027257931781844e-1*"AVG_BAR"-4.4581479795923362e-1 )
WHEN "AVG_BAR" <= 4.2769230769240769e0 THEN  ( 1.2027257931781807e-1*"AVG_BAR"-4.4581479795756696e-1 )
WHEN "AVG_BAR" <= 4.4010427444473326e0 THEN  ( -1.4877282578461165e-1*"AVG_BAR"+7.0487170386328624e-1 )
WHEN "AVG_BAR" <= 4.5000000000010001e0 THEN  ( -2.3009382816284152e-1*"AVG_BAR"+1.0627689113488206e0 )
WHEN "AVG_BAR" <= 4.5000358651803145e0 THEN  ( -6.1582387180856369e2*"AVG_BAR"+2.7712347698231506e3 )
WHEN "AVG_BAR" <= 4.5001000000009999e0 THEN  ( -1.9258633192564488e2*"AVG_BAR"+8.66650660859754e2 )
WHEN "AVG_BAR" <= 4.5500500000009998e0 THEN  ( 2.4036555713251939e-1*"AVG_BAR"-1.0887604824911792e0 )
WHEN "AVG_BAR" <= 4.6000000000009997e0 THEN  ( 2.4036555713251939e-1*"AVG_BAR"-1.0887604824899788e0 )
WHEN "AVG_BAR" <= 4.643283582090552e0 THEN  ( 2.7844912494707252e-1*"AVG_BAR"-1.2639448944357181e0 )
WHEN "AVG_BAR" <= 4.6865671641801043e0 THEN  ( 2.7844912494707769e-1*"AVG_BAR"-1.2639448944345373e0 )
WHEN "AVG_BAR" <= 4.8950849216725913e0 THEN  ( -6.6135245924575273e-2*"AVG_BAR"+3.5097290338048731e-1 )
WHEN "AVG_BAR" <= 5.0000000000010001e0 THEN  ( -2.4087849018176835e-1*"AVG_BAR"+1.2063559235053218e0 )
ELSE 1.9634725964801092e-3
END) AS DOUBLE) )  AS DOUBLE) AS predict_pret_a_manger,
NB_RETAIL_BIG,NB_RETAIL_SMALL, NB_BAR,NB_SANDWICH,NB_RESTAURANT,NB_LT_3,NB_RESTAURANT_5,AVG_BAR
	      from :clusters;

	   return
	   select id,
	   shape.ST_Transform(4326) as shape,
	   to_integer(least(predict_pret_a_manger+0.2,0.92)*10) as predict_pret_a_manger,
	   NB_RETAIL_BIG,NB_RETAIL_SMALL, NB_BAR,NB_SANDWICH,NB_RESTAURANT,NB_LT_3,NB_RESTAURANT_5,AVG_BAR, :radius as radius
	   from :prediction
	      where predict_pret_a_manger>0.1;
end ;


-------------
--  computes geo indicator around each store "Pret A Manger"
CREATE or replace FUNCTION food_rating.F_GEOINDICATOR(VIEW_EXTENT NVARCHAR(400),radius INT)
RETURNS
TABLE (
  ID int,
  NB_RETAIL_BIG int,
	NB_RETAIL_SMALL int,
	NB_BAR int,
	NB_SANDWICH int,
	NB_RESTAURANT int,
	NB_LT_3 int,
	NB_RESTAURANT_5 int,
	AVG_RATING_BAR double,
	TOTAL_CNT int,
	shape ST_Geometry(4326)
) lANGUAGE SQLSCRIPT as
BEGIN

    declare cat_retail_big   nvarchar(64)= 'Retailers - supermarkets/hypermarkets';
    declare cat_retail_small nvarchar(64)= 'Retailers - other';
    declare cat_bar          nvarchar(64)= 'Pub/bar/nightclub';
    declare cat_sandwich     nvarchar(64)= 'Takeaway/sandwich shop';
    declare cat_restaurant   nvarchar(64)= 'Restaurant/Cafe/Canteen';

	res = SELECT t1.id,
	      t1.PT as pt,
       to_integer(sum(case t2.businesstype when :cat_retail_big   then 1 else 0 end)) as NB_RETAIL_BIG,
		to_integer(sum(case t2.businesstype when :cat_retail_small then 1 else 0 end)) as NB_RETAIL_SMALL,
		to_integer(sum(case t2.businesstype when :cat_bar          then 1 else 0 end)) as NB_BAR,
		to_integer(sum(case t2.businesstype when :cat_sandwich     then 1 else 0 end)) as NB_SANDWICH,
		to_integer(sum(case t2.businesstype when :cat_restaurant   then 1 else 0 end)) as NB_RESTAURANT,
		to_integer(sum(case when t2.ratingvalue <=3 then 1 else 0 end)) as NB_LT_3,
		to_integer(sum(case when t2.businesstype = :cat_restaurant and t2.ratingvalue=5 then 1 else 0 end)) as NB_RESTAURANT_5,
		to_decimal(avg(case t2.businesstype when :cat_bar          then t2.ratingvalue end),2,1) as AVG_RATING_BAR,
		to_integer(count(*)) as TOTAL_CNT
	from food_rating.FHR t1
	  INNER JOIN  food_rating.FHR t2
	    ON ( t2.LATITUDE BETWEEN T1.LATITUDE -0.005 AND  T1.LATITUDE +0.005
	      AND t2.LONGITUDE BETWEEN T1.LONGITUDE -0.005 AND  T1.LONGITUDE +0.005
	      AND t2.id<> t1.id)
	where t1.pt is not null
		and InitCap(t1.businessname) like InitCap('pret %')
		AND t1.PT.ST_WithinDistance(t2.PT, :radius, 'meter')=1
		and t1.pt.ST_Within(ST_GeomFromText(:VIEW_EXTENT, 1000004326))=1
	GROUP BY t1.id, t1.pt ;

    return select id, NB_RETAIL_BIG, NB_RETAIL_SMALL, NB_BAR, NB_SANDWICH, NB_RESTAURANT, NB_LT_3, NB_RESTAURANT_5, AVG_RATING_BAR,
    		TOTAL_CNT,
           PT.ST_transform(3857).ST_Buffer(:radius, 'meter').ST_Transform(4326) as shape
    from :res;

END
