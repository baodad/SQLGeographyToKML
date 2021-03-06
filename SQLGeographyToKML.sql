/*
2018-01-11
A user-defined function that converts certain SQL geography (POINTs, POLYGONs, and MULTIPOLYGONs)
to a KML snippet (to be included in a larger KML file)

Use like:
select ConvertSQLGeoToKML_SVF(<Geography data type>)
*/

CREATE FUNCTION ConvertSQLGeoToKML_SVF (
	@geo geography
)
RETURNS varchar(max)
AS
BEGIN
	-- Declare the return variable here
	DECLARE @kml varchar(max)

	/*
	From https://developers.google.com/kml/documentation/altitudemode
	Any KML feature with no altitude mode specified will default to clampToGround.
	*/

	DECLARE @wkt varchar(max)
	DECLARE @i int, @ShapeType varchar(30)
	DECLARE @start int, @end int
	DECLARE @tempreplace varchar(max)

	--Table will be used to help split up MULTIPOLYGONs
	DECLARE @tbl TABLE (
		ID int primary key identity(1,1),
		CentroidCount int,
		MainShape varchar(max),
		Centroids varchar(max))
	DECLARE @CentroidSearchFor varchar(20) = '), ('
	DECLARE @CentroidStart int
	DECLARE @CentroidStr varchar(max)
	DECLARE @GeoStrToInsert varchar(max)
	DECLARE @MyCount int

	SET @wkt = @geo.STAsText()

	--select @wkt
	--return

	--Determine shape type
	SELECT @ShapeType = rtrim(SUBSTRING(@wkt,1,CHARINDEX(' (',@wkt)))
	--Shape should be either MULTIPOLYGON or POLYGON
	IF @ShapeType NOT IN ('MULTIPOLYGON','POLYGON','POINT')
		SET @kml = '#ERROR: Geography does not seem to be a POINT, POLYGON, or MULTIPOLYGON.'

	IF @ShapeType = 'POINT'
	BEGIN
		set @wkt = REPLACE(@wkt,'POINT (','')
		set @wkt = REPLACE(@wkt,')','')
		SET @wkt = REPLACE(@wkt,' ',',')
		select @kml =
			CONVERT(varchar(max),
			(
				select
					@wkt "coordinates"
				FOR XML PATH ('Point')
			)
		)
	END

	IF @ShapeType = 'POLYGON'
	BEGIN
		set @wkt = REPLACE(@wkt,'POLYGON ((','')
		set @wkt = REPLACE(@wkt,'))','')
		SET @CentroidStart = CHARINDEX(@CentroidSearchFor,@wkt)
		IF @CentroidStart > 0 --then there are centroids
		BEGIN
			SET @CentroidStr = SUBSTRING(@wkt, @CentroidStart+LEN(@CentroidSearchFor), LEN(@wkt))
			SET @CentroidStr = REPLACE(@CentroidStr,@CentroidSearchFor,'|')
			--Now remove the centroids from the main shape:
			SET @wkt = SUBSTRING(@wkt,1,@CentroidStart-1)
			SET @tempreplace = REPLACE(@CentroidStr,', ',';')
			SET @tempreplace = REPLACE(@tempreplace,' ',',')
			SET @CentroidStr = REPLACE(@tempreplace,';',' ')
		END
		SET @tempreplace = REPLACE(@wkt,', ',';')
		SET @tempreplace = REPLACE(@tempreplace,' ',',')
		SET @wkt = REPLACE(@tempreplace,';',' ')
		select @kml =
			REPLACE(
				CONVERT(varchar(max),
					(
						select
							1 as tessellate,
							@wkt "outerBoundaryIs/LinearRing/coordinates",
							@CentroidStr "innerBoundaryIs/LinearRing/coordinates"
						FOR XML PATH ('Polygon')
					)
				),'|','</coordinates></LinearRing></innerBoundaryIs><innerBoundaryIs><LinearRing><coordinates>'
			)
	END

	IF @ShapeType = 'MULTIPOLYGON'
	BEGIN
		set @wkt = REPLACE(@wkt,'MULTIPOLYGON (','')
		set @wkt = SUBSTRING(@wkt,1,LEN(@wkt)-1)

		SELECT @i = 0
		WHILE 1=1
		BEGIN
			SET @start = CHARINDEX('((',@wkt,@i)
			IF @start = 0 BREAK
			SET @end = CHARINDEX('))',@wkt,@start)
			SET @GeoStrToInsert = SUBSTRING(@wkt,@start+2,@end-(@start+2))
			SET @MyCount = (LEN(@GeoStrToInsert) - LEN(REPLACE(@GeoStrToInsert, @CentroidSearchFor, ''))) / LEN(@CentroidSearchFor)
			SET @CentroidStart = CHARINDEX(@CentroidSearchFor,@GeoStrToInsert)
			IF @CentroidStart > 0 --then there are centroids
			BEGIN
				SET @CentroidStr = SUBSTRING(@GeoStrToInsert, @CentroidStart+LEN(@CentroidSearchFor), LEN(@GeoStrToInsert))
				--Now remove the centroids from the main shape:
				SET @GeoStrToInsert = SUBSTRING(@GeoStrToInsert,1,@CentroidStart-1)
			END
			ELSE
				SET @CentroidStr = NULL
			--KML uses spaces and commas exactly opposite to the way WKT does:
			SET @CentroidStr = REPLACE(@CentroidStr,@CentroidSearchFor,'|')
			SET @tempreplace = REPLACE(@CentroidStr,', ',';')
			SET @tempreplace = REPLACE(@tempreplace,' ',',')
			SET @CentroidStr = REPLACE(@tempreplace,';',' ')
			SET @tempreplace = REPLACE(@GeoStrToInsert,', ',';')
			SET @tempreplace = REPLACE(@tempreplace,' ',',')
			SET @GeoStrToInsert = REPLACE(@tempreplace,';',' ')
			INSERT @tbl (CentroidCount, MainShape, Centroids)
			VALUES (@MyCount, @GeoStrToInsert, @CentroidStr)
			SET @i = @end
			--PRINT '@i is now ' + CONVERT(varchar(20),@i)
		END
		--select * from @tbl;return

		--Convert output to varchar(max) because we can't copy more than 4000 some-odd characters from SSMS,
		--and 'Save Results As...' from XML has a line length of 2033 characters before it adds line breaks.
		select @kml =
			REPLACE(
			CONVERT(varchar(max),
				(
					select
						--I think we want to specify name and style at the Placemark level, not here
						--But if we did want to specify them here, we could do it like this:
						--'namehere' as "name",
						--'#blahblah' as StyleURL,
						--See note below after FOR XML PATH ('MultiGeometry')
						(
						select
						1 as tessellate,
						MainShape "outerBoundaryIs/LinearRing/coordinates",
						(SELECT Centroids [data()]
							   FROM   @tbl t1
							   WHERE  t0.ID = t1.ID
							   and CentroidCount > 0
							   FOR XML PATH ('')
						) AS "innerBoundaryIs/LinearRing/coordinates"
						FROM @tbl t0
						FOR XML PATH ('Polygon') --, ROOT ('MultiGeometry')
						,TYPE)  --TYPE is magic word so outer FOR XML doesn't escape all the inner XML to &gt; type stuff
					FOR XML PATH ('MultiGeometry') --This outer SELECT ... FOR XML isn't necessary. We could do it with the ROOT ('MultiGeometry') piece above, but I don't want to forget how to export XML like this
				)
			),'|','</coordinates></LinearRing></innerBoundaryIs><innerBoundaryIs><LinearRing><coordinates>'
		)
	END

	-- Return the result of the function
	RETURN @kml
END
