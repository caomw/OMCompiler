/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2008, Link�pings University,
 * Department of Computer and Information Science,
 * SE-58183 Link�ping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF THIS OSMC PUBLIC
 * LICENSE (OSMC-PL). ANY USE, REPRODUCTION OR DISTRIBUTION OF
 * THIS PROGRAM CONSTITUTES RECIPIENT'S ACCEPTANCE OF THE OSMC
 * PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Link�pings University, either from the above address,
 * from the URL: http://www.ida.liu.se/projects/OpenModelica
 * and in the OpenModelica distribution.
 *
 * This program is distributed  WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 *
 * For more information about the Qt-library visit TrollTech:s webpage regarding
 * licence: http://www.trolltech.com/products/qt/licensing.html
 *
 */

#ifndef SENDDATA_H
#define SENDDATA_H

#ifdef __cplusplus
using namespace std;
extern "C"
{
#endif

class Static
{
	public:
/*	static QTcpSocket* socket;
	static QTcpSocket socket1, socket2;
	static QByteArray* block;
	static QDataStream* out;
	static Connection* c;
*/	static bool enabled();
	static bool enabled_;
/*	static int port1, port2;
	static QStringList* filterVariables;

	static bool connect(bool graphics = false);
	*/
};

void _errmesg();
/*
	void emulateStreamData(const char* data, int port=7778, const char* title="Plot by OpenModelica", const char* xLabel = "time", const char* yLabel = "", const char* interpolation="linear", int legend = 1, int grid = 1, double xMin=0, double xMax=0, double yMin=0, double yMax=0, int logX=0, int logY=0, int drawPoints = 1, const char* range = "0.0,0.0 0.0,0.0");

	bool plt(const char* var, const char* mdl, const char* title, const char* xLabel, const char* yLabel, bool legend, bool grid, double xmin, double xmax, double ymin, double ymax, bool logX, bool logY, const char* interpolation, bool drawPoints, const char* range);
	bool pltParametric(const char*, const char*, const char*);
	bool clear();
	bool ellipse(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);
	bool rect(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);
	bool line(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);

	bool hold(int = 1);
	bool pltWait(unsigned long msecs);
*/
///////////////
	void setVariableFilter(const char* variables);
	void setDataPort(int port);
	void enableSendData(int enable);
	//void initSendData(int variableCount, const char* variableNames);
	void initSendData(int variableCount1, int variableCount2, char** statesNames, char** stateDerivativesNames,  char** algebraicsNames);
	void sendPacket(const char* data);
	void closeSendData();

	void emulateStreamData(const char* data, const char* title="Plot by OpenModelica", const char* xLabel = "time", const char* yLabel = "", const char* interpolation="linear", int legend = 1, int grid = 1, int logX=0, int logY=0, int drawPoints = 1, const char* range = "0.0,0.0 0.0,0.0");
	void emulateStreamData2(const char* info, const char* data, int port=7778);

	bool pltTable(double*, size_t r, size_t c); //, const char*, int size);
	bool plt(const char* var, const char* mdl, const char* title, const char* xLabel, const char* yLabel, bool legend, bool grid, double xmin, double xmax, double ymin, double ymax, bool logX, bool logY, const char* interpolation, bool drawPoints, const char* range);
	bool pltParametric(const char*, const char*, const char*);
	bool clear();
	bool ellipse(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);
//	bool ellipse(double x0, double y0, double x1, double y1, const char* color, int* colorRGB, int tmp1, const char* fillColor, int* fillColorRGB, int tmp2);
	bool rect(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);
	bool line(double x0, double y0, double x1, double y1, const char* color, int colorR, int colorG, int colorB, const char* fillColor, int fillColorR, int fillColorG, int fillColorB);

	bool hold(int = 1);
	bool pltWait(unsigned long msecs);

	int getVariableListSize(const char* model);
	bool getVariableList(const char* model, char* lst);

#ifdef __cplusplus
}
#endif


#endif
